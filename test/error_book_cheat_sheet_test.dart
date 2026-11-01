import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:natsume_quiz_master/models/answer_record.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/error_book_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_prompt_service.dart';

/// 错题本的「考前小抄」（v1.37 · P1）。
///
/// 这一层要守的是**接线**，不是提示词内容：
/// 1. 没有插件提供 `prompts/cheat_sheet.md` 时，不偷偷用宿主提示词顶替，
///    也不白花一次 AI 请求——直接告诉用户去哪里装插件；
/// 2. 有模板时，错题正文必须真的填进 `{{ERROR_QUESTIONS}}`（不能把占位符
///    原样发给模型），system 里带上插件的风格约定；
/// 3. 生成结果流式渲染成富文本（`##`/`**` 不能裸奔给用户看）。
void main() {
  late Directory tmp;
  late Directory pluginRoot;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_cheat_sheet_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
    pluginRoot = Directory('${tmp.path}/plugins')..createSync(recursive: true);
    PluginPromptService.instance.clear();
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    PluginPromptService.instance.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  PluginInfo installed(String id) => PluginInfo(
        id: id,
        name: id,
        version: '1.0.0',
        enabled: true,
        installedAt: DateTime.now().toIso8601String(),
      );

  void writePlugin(
    String id, {
    required String prompt,
    required Map<String, String> templates,
  }) {
    final dir = Directory('${pluginRoot.path}/$id')
      ..createSync(recursive: true);
    File('${dir.path}/plugin.json').writeAsStringSync(jsonEncode({
      'id': id,
      'name': '小抄插件',
      'version': '1.0.0',
    }));
    File('${dir.path}/prompt.md').writeAsStringSync(prompt);
    templates.forEach((fileName, content) {
      Directory('${dir.path}/prompts').createSync(recursive: true);
      File('${dir.path}/prompts/$fileName').writeAsStringSync(content);
    });
  }

  Future<void> seedErrorQuestion(String title, String kp) async {
    final db = DatabaseService.instance;
    final bankId = await db.insertBank(QuestionBank(
        name: '题库_$title', createdAt: DateTime.now().toIso8601String()));
    await db.insertQuestions([
      Question(
        bankId: bankId,
        title: title,
        options: const ['A项', 'B项'],
        correctAnswer: 'B',
        analysis: '肉芽组织由新生毛细血管和成纤维细胞组成。',
        knowledgePoint: kp,
        createdAt: DateTime.now().toIso8601String(),
      ),
    ]);
    final qid = (await db.getQuestionsByBank(bankId)).first.id!;
    await db.addToErrorBook(qid);
    // 两次作答都错：小抄排序看的就是「错了几次」
    for (var i = 0; i < 2; i++) {
      await db.insertAnswerRecord(AnswerRecord(
          questionId: qid,
          userAnswer: 'A',
          isCorrect: false,
          answeredAt: DateTime.now().toIso8601String()));
    }
  }

  Future<void> settleUntil(WidgetTester tester, Finder target,
      {String? what}) async {
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 10));
      if (target.evaluate().isNotEmpty) return;
    }
    fail('等不到${what ?? '目标控件'}渲染');
  }

  testWidgets('没有插件模板：不发请求，只提示去插件市场装', (tester) async {
    final bodies = <String>[];
    final client = MockClient((request) async {
      bodies.add(request.body);
      return http.Response.bytes(utf8.encode('{}'), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

    tester.view.physicalSize = const Size(411, 891);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState appState;
    await tester.runAsync(() async {
      await seedErrorQuestion('病理题', '病理学');
      appState = AppState(aiClient: client);
      await appState.init();
      await appState.updateSettings(
          AppSettings(apiKey: 'sk-test', model: 'test-model'));
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: ErrorBookScreen()),
    ));
    final button = find.byTooltip('生成考前小抄');
    await settleUntil(tester, button, what: '考前小抄按钮');

    await tester.tap(button);
    await settleUntil(tester, find.textContaining('没有已启用的插件'),
        what: '缺少模板的提示');

    expect(bodies, isEmpty, reason: '模板缺失时不该白花一次 AI 请求');
    expect(find.text('考前小抄'), findsNothing, reason: '提示即可，不必开空弹窗');
  });

  testWidgets('有插件模板：题干填进占位符，结果按富文本流式显示', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient.streaming((request, bodyStream) async {
      final body = await bodyStream.bytesToString();
      bodies.add(jsonDecode(body) as Map<String, dynamic>);
      final lines = <String>[
        'data: {"choices":[{"delta":{"content":"## 考前速记"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"\\n**病理学**：背肉芽组织"}}]}',
        '',
        'data: [DONE]',
        '',
      ];
      return http.StreamedResponse(
        Stream.value(utf8.encode(lines.join('\n'))),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    tester.view.physicalSize = const Size(411, 891);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState appState;
    await tester.runAsync(() async {
      writePlugin(
        'com.example.cheat',
        prompt: '小抄要写成表格。',
        templates: {
          'cheat_sheet.md': '按下列错题生成小抄：\n{{ERROR_QUESTIONS}}\n'
              '共 {{ERROR_COUNT}} 题，范围 {{SCOPE}}。',
        },
      );
      await seedErrorQuestion('病理题', '病理学');
      appState = AppState(aiClient: client);
      await appState.init();
      await appState.updateSettings(
          AppSettings(apiKey: 'sk-test', model: 'test-model'));
      // 注意顺序：init() 里会按数据库里的启用状态刷新一次（测试库没有已装插件，
      // 等于清空），所以插件的内存快照必须在 init 之后再刷，否则被覆盖成空。
      await PluginPromptService.instance.refresh(
        root: pluginRoot,
        installed: [installed('com.example.cheat')],
      );
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: ErrorBookScreen()),
    ));
    final button = find.byTooltip('生成考前小抄');
    await settleUntil(tester, button, what: '考前小抄按钮');

    await tester.tap(button);
    await settleUntil(tester, find.text('考前小抄'), what: '小抄弹窗');
    await settleUntil(tester, find.textContaining('考前速记'), what: '流式小抄内容');

    // 1) 请求体：占位符全部换掉，错题正文真的进去了
    expect(bodies, hasLength(1));
    final messages = (bodies.single['messages'] as List).cast<Map>();
    final system = messages.first['content'] as String;
    expect(messages.first['role'], 'system');
    expect(system, contains('小抄要写成表格'));
    final user = messages.last['content'] as String;
    expect(user, contains('病理题'));
    expect(user, contains('肉芽组织由新生毛细血管'), reason: '解析也要带上，小抄才有出处');
    expect(user.contains('{{'), isFalse, reason: '占位符不能原样发给模型');
    expect(user, contains('共 1 题'));

    // 2) 渲染：markdown 标记按格式生效，不把源码摊给用户
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('病理学'), findsWidgets);
    // 3) 副标题写清范围与题量（用户要知道这份小抄覆盖了什么）
    expect(find.textContaining('道错题'), findsWidgets);
  });
}
