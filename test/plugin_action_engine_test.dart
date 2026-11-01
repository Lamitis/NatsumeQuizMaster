import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_action_engine.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_prompt_service.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_ui_extension.dart';
import 'package:natsume_quiz_master/widgets/plugin_action_sheet.dart';

/// 契约驱动的插件动作引擎（v1.38）。
///
/// 这里锁住四条硬约束：
/// 1. 清单只认白名单（槽位 / 动作 / 上下文 / 渲染器），未知值直接丢弃；
/// 2. 只采集插件声明过的上下文切片，题目 3000 字、错题 10 条强制截断；
/// 3. 插件提示词只作为 user 消息，system 仍是宿主底线；
/// 4. 可折叠渲染器在 `<!--ANSWER_START-->` 处默认收起答案，并显示免责声明。
void main() {
  late Directory tmp;

  PluginInfo installed(String id, {bool enabled = true}) => PluginInfo(
        id: id,
        name: id,
        version: '1.0.0',
        enabled: enabled,
        installedAt: DateTime.now().toIso8601String(),
      );

  Map<String, dynamic> manifestExtension({
    String slot = PluginSlots.quizAnalysisActions,
    String label = '深度解析',
    String icon = 'psychology',
    String renderer = PluginRenderers.bottomSheetFoldable,
    List<String> contexts = const [
      PluginContextKeys.questionText,
      PluginContextKeys.questionOptions,
      PluginContextKeys.correctAnswer,
    ],
    String promptTemplate = '题目：{{QUESTION_TEXT}}\n'
        '选项：{{QUESTION_OPTIONS}}\n答案：{{CORRECT_ANSWER}}\n'
        '未知槽位：{{UNKNOWN_SLOT}}',
  }) =>
      {
        'slot': slot,
        'label': label,
        'icon': icon,
        'action': {
          'type': PluginActionTypes.aiPrompt,
          'contexts': contexts,
          'prompt_template': promptTemplate,
          'renderer': renderer,
        },
      };

  /// 彩蛋 Mock：解析器 Sakuraba_Ema / 验证器 Nikaido_Hiro
  const mockPluginId = 'com.example.sakuraba';
  const mockPluginName = 'Sakuraba_Ema_Plugin';

  PluginUiExtension parseOne(Map<String, dynamic> raw) =>
      PluginUiExtension.parseList(
        [raw],
        pluginId: mockPluginId,
        pluginName: mockPluginName,
      ).single;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_plugin_engine_');
    PluginPromptService.instance.clear();
  });

  tearDown(() {
    PluginPromptService.instance.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('契约解析：未知槽位 / 动作 / 上下文被白名单丢弃', () {
    final nikaidoHiro = PluginUiExtension.parseList(
      [
        manifestExtension(),
        manifestExtension(slot: 'admin_console'),
        {
          'slot': PluginSlots.errorBookActions,
          'label': '危险动作',
          'icon': 'psychology',
          'action': {
            'type': 'run_shell',
            'contexts': ['question_text'],
            'prompt_template': 'rm -rf /',
          },
        },
        manifestExtension(
          contexts: [
            PluginContextKeys.questionText,
            'api_key',
            'database_dump',
            PluginContextKeys.correctAnswer,
            PluginContextKeys.questionText,
          ],
        ),
      ],
      pluginId: mockPluginId,
      pluginName: mockPluginName,
    );

    expect(nikaidoHiro, hasLength(2), reason: '只有两条合法扩展');
    expect(nikaidoHiro.first.slot, PluginSlots.quizAnalysisActions);
    expect(nikaidoHiro.first.action.contexts, [
      PluginContextKeys.questionText,
      PluginContextKeys.questionOptions,
      PluginContextKeys.correctAnswer,
    ]);
    expect(
        nikaidoHiro.first.action.renderer, PluginRenderers.bottomSheetFoldable);
  });

  test('契约解析：单插件最多 8 条，超长按钮文字与坏图标被兜底', () {
    final raw = List.generate(12, (i) => manifestExtension(label: '动作$i'));
    final sakurabaEma = PluginUiExtension.parseList(
      raw,
      pluginId: mockPluginId,
      pluginName: mockPluginName,
    );
    expect(sakurabaEma, hasLength(PluginUiExtension.maxPerPlugin));

    final fallback = parseOne(manifestExtension(
      label: '正常按钮',
      icon: 'not-a-real-icon-name-too-long',
    ));
    expect(fallback.icon, 'extension');

    final tooLong = PluginUiExtension.parseList(
      [manifestExtension(label: '超' * 40)],
      pluginId: mockPluginId,
      pluginName: mockPluginName,
    );
    expect(tooLong, isEmpty);
  });

  test('上下文切片：只给声明过的数据，并且强制截断', () {
    final longQuestion = '题' * 4000;
    final context = PluginActionContext(
      questionText: longQuestion,
      options: const ['A项', 'B项'],
      correctAnswer: 'B',
      analysis: '解析内容',
      errorQuestions: List.generate(15, (i) => '错题$i：题干'),
      errorCount: 15,
    );

    final vars = context.select([
      PluginContextKeys.questionText,
      PluginContextKeys.errorQuestions,
    ]);

    expect(vars.containsKey('CORRECT_ANSWER'), isFalse,
        reason: '未声明的上下文一个字节都不给');
    expect(vars.containsKey('ANALYSIS'), isFalse);
    expect(vars['QUESTION_TEXT']!.length,
        lessThanOrEqualTo(PluginActionContext.maxQuestionTextChars + 1));
    expect(vars['QUESTION_TEXT']!.endsWith('…'), isTrue);

    final errors = vars['ERROR_QUESTIONS']!;
    expect(errors, contains('错题0'));
    expect(errors, contains('错题9'));
    expect(errors.contains('错题10'), isFalse, reason: '错题最多 10 条');
    expect(errors.length,
        lessThan(PluginActionContext.maxErrorQuestionsChars + 64));
  });

  test('填模板：已知占位符被替换，未知占位符原样保留', () {
    final extension = parseOne(manifestExtension());
    final prompt = PluginActionEngine.buildPrompt(
      extension,
      const PluginActionContext(
        questionText: '病理切片里看到了什么？',
        options: ['肉芽组织', '瘢痕组织'],
        correctAnswer: 'A',
      ),
    )!;

    expect(prompt, contains('病理切片里看到了什么？'));
    expect(prompt, contains('A. 肉芽组织'));
    expect(prompt, contains('答案：A'));
    expect(prompt.contains('{{QUESTION_TEXT}}'), isFalse);
    expect(prompt, contains('{{UNKNOWN_SLOT}}'), reason: '拼错的槽位要看得见，不能悄悄吞掉');
  });

  test('refresh：只有 ui_extensions 的插件也会登记，停用则不登记', () async {
    final dir = Directory('${tmp.path}/sakuraba')..createSync(recursive: true);
    // 刻意不写 prompt.md：UI 扩展不该依赖提示词文件
    File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
      'id': mockPluginId,
      'name': mockPluginName,
      'version': '1.0.0',
      'ui_extensions': [manifestExtension()],
    }));

    await PluginPromptService.instance.refresh(
      root: tmp,
      installed: [installed(mockPluginId)],
    );
    expect(PluginPromptService.instance.packs, isEmpty);
    expect(PluginPromptService.instance.uiExtensions, hasLength(1));
    expect(
      PluginPromptService.instance
          .extensionsFor(PluginSlots.quizAnalysisActions),
      hasLength(1),
    );
    expect(
      PluginPromptService.instance.extensionsFor(PluginSlots.errorBookActions),
      isEmpty,
    );

    await PluginPromptService.instance.refresh(
      root: tmp,
      installed: [installed(mockPluginId, enabled: false)],
    );
    expect(PluginPromptService.instance.uiExtensions, isEmpty);
  });

  test('AI 接线：插件模板只进 user 消息，system 仍是宿主底线', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient.streaming((request, bodyStream) async {
      bodies.add(
          jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>);
      final lines = <String>[
        'data: {"choices":[{"delta":{"content":"结论"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"先行"}}]}',
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

    final ai = AIService(
      AppSettings(apiKey: 'sk-test', model: 'test-model'),
      client: client,
    );
    final extension = parseOne(manifestExtension(
      contexts: [PluginContextKeys.questionText],
    ));
    final chunks = await PluginActionEngine.streamAction(
      extension: extension,
      context: const PluginActionContext(
        questionText: '题干可见',
        correctAnswer: 'CORRECT_SECRET_B',
      ),
      ai: ai,
    ).toList();

    expect(chunks.last, '结论先行');
    expect(bodies, hasLength(1));
    final messages = (bodies.single['messages'] as List).cast<Map>();
    expect(messages.first['role'], 'system');
    expect(messages.first['content'], AIService.baseSystemPrompt,
        reason: '插件不能覆盖 system');
    final user = messages.last['content'] as String;
    expect(user, contains('题干可见'));
    expect(user.contains('CORRECT_SECRET_B'), isFalse,
        reason: '没声明 correct_answer 就不能采集');
    ai.dispose();
  });

  testWidgets('可折叠渲染器：答案默认收起，展开后可见，并带免责声明', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPluginActionResultSheet(
              context,
              title: '深度解析',
              pluginName: mockPluginName,
              stream: Stream<String>.fromIterable(const [
                '先讲思路：看病理切片。\n'
                    '${PluginRenderers.answerStartMarker}'
                    '\n最终答案是 A。',
              ]),
              renderer: PluginRenderers.bottomSheetFoldable,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('深度解析'), findsOneWidget);
    expect(find.textContaining('先讲思路'), findsWidgets);
    expect(find.textContaining('最终答案是 A'), findsNothing, reason: '答案默认折叠');
    expect(find.text(pluginActionDisclaimer), findsOneWidget);

    await tester.tap(find.text('展开查看答案'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最终答案是 A'), findsWidgets);
  });
}
