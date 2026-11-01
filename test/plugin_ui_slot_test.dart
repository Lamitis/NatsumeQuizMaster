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
import 'package:natsume_quiz_master/services/plugins/plugin_ui_extension.dart';
import 'package:natsume_quiz_master/widgets/plugin_action_sheet.dart';

/// 动态 UI 插槽的页面级接线（v1.38）。
///
/// 只看两件事：声明了 `error_book_actions` 的插件会在错题本出现图标按钮；
/// 点下去确实用宿主查到的错题填 `{{ERROR_QUESTIONS}}`，并弹出带免责声明的
/// 结果弹层。契约解析与截断由 `plugin_action_engine_test.dart` 覆盖。
void main() {
  late Directory tmp;
  late Directory pluginRoot;

  const mockPluginId = 'com.example.jogasaki';
  const mockPluginName = 'Jogasaki_Noah_Plugin';
  const actionLabel = '错题串讲';

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_plugin_slot_');
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

  void writePlugin() {
    final dir = Directory('${pluginRoot.path}/$mockPluginId')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
      'id': mockPluginId,
      'name': mockPluginName,
      'version': '1.0.0',
      'ui_extensions': [
        {
          'slot': PluginSlots.errorBookActions,
          'label': actionLabel,
          'icon': 'tips_and_updates',
          'action': {
            'type': PluginActionTypes.aiPrompt,
            'contexts': [
              PluginContextKeys.errorQuestions,
              PluginContextKeys.errorCount,
              PluginContextKeys.scope,
            ],
            'prompt_template':
                '范围：{{SCOPE}}\n共 {{ERROR_COUNT}} 题：\n{{ERROR_QUESTIONS}}',
            'renderer': PluginRenderers.bottomSheet,
          },
        },
      ],
    }));
  }

  Future<void> seedErrorQuestion() async {
    final db = DatabaseService.instance;
    final bankId = await db.insertBank(QuestionBank(
        name: '题库_病理', createdAt: DateTime.now().toIso8601String()));
    await db.insertQuestions([
      Question(
        bankId: bankId,
        title: '病理题：肉芽组织的主要成分？',
        options: const ['新生毛细血管', '瘢痕组织'],
        correctAnswer: 'A',
        analysis: '肉芽组织由新生毛细血管和成纤维细胞组成。',
        knowledgePoint: '病理学',
        createdAt: DateTime.now().toIso8601String(),
      ),
    ]);
    final qid = (await db.getQuestionsByBank(bankId)).first.id!;
    await db.addToErrorBook(qid);
    await db.insertAnswerRecord(AnswerRecord(
      questionId: qid,
      userAnswer: 'B',
      isCorrect: false,
      answeredAt: DateTime.now().toIso8601String(),
    ));
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

  testWidgets('error_book_actions：动态按钮执行插件动作并显示免责声明', (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient.streaming((request, bodyStream) async {
      bodies.add(
          jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>);
      final lines = <String>[
        'data: {"choices":[{"delta":{"content":"串讲结论"}}]}',
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
      writePlugin();
      await seedErrorQuestion();
      appState = AppState(aiClient: client);
      await appState.init();
      await appState
          .updateSettings(AppSettings(apiKey: 'sk-test', model: 'test-model'));
      // init() 会按库里的插件刷新一次快照，所以测试插件要在 init 之后再登记
      await PluginPromptService.instance.refresh(
        root: pluginRoot,
        installed: [installed(mockPluginId)],
      );
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: ErrorBookScreen()),
    ));

    final button = find.byTooltip(actionLabel);
    await settleUntil(tester, button, what: '动态插件按钮');
    await tester.tap(button);
    await settleUntil(tester, find.text(actionLabel), what: '插件结果弹层');

    expect(find.text(pluginActionDisclaimer), findsOneWidget);
    await settleUntil(tester, find.textContaining('串讲结论'), what: '流式结果');
    expect(bodies, hasLength(1));
    final messages = (bodies.single['messages'] as List).cast<Map>();
    final user = messages.last['content'] as String;
    expect(user, contains('病理题：肉芽组织的主要成分？'));
    expect(user, contains('共 1 题'));
    expect(user.contains('{{'), isFalse, reason: '占位符不能原样发给模型');
  });
}
