import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_prompt_service.dart';

/// 宿主代劳的插件提示词（v1.37 · P0）。
///
/// 这里测的是**接线**：插件提示词怎么进 system 消息、模板怎么变成 user 消息。
/// 净化与限长本身由 `plugin_prompt_service_test.dart` 单独覆盖。
void main() {
  late Directory tmp;

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
    Map<String, String> templates = const {},
  }) {
    final dir = Directory('${tmp.path}/$id')..createSync(recursive: true);
    File('${dir.path}/plugin.json').writeAsStringSync(jsonEncode({
      'id': id,
      'name': '插件$id',
      'version': '1.0.0',
    }));
    File('${dir.path}/prompt.md').writeAsStringSync(prompt);
    templates.forEach((fileName, content) {
      Directory('${dir.path}/prompts').createSync(recursive: true);
      File('${dir.path}/prompts/$fileName').writeAsStringSync(content);
    });
  }

  /// 捕获请求体，回一句固定内容（非流式）
  MockClient capturing(List<Map<String, dynamic>> bodies) =>
      MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '依据错题生成的小抄'}
              }
            ]
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

  AIService service(http.Client client) => AIService(
        AppSettings(apiKey: 'sk-test', model: 'test-model'),
        client: client,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_plugin_ai_');
    PluginPromptService.instance.clear();
  });

  tearDown(() {
    PluginPromptService.instance.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('没启用插件时：system 提示词与改造前完全一致', () {
    final ai = service(capturing(<Map<String, dynamic>>[]));
    expect(ai.hasPluginPrompts, isFalse);
    expect(ai.effectiveSystemPrompt, AIService.baseSystemPrompt);
    ai.dispose();
  });

  test('启用插件后：宿主底线在前，插件文本只能追加在后', () async {
    writePlugin('com.example.style', prompt: '讲解时先给结论，再给机制。');
    await PluginPromptService.instance
        .refresh(root: tmp, installed: [installed('com.example.style')]);

    final ai = service(capturing(<Map<String, dynamic>>[]));
    final prompt = ai.effectiveSystemPrompt;
    expect(ai.hasPluginPrompts, isTrue);
    expect(prompt.startsWith(AIService.baseSystemPrompt), isTrue,
        reason: '插件不能替换宿主底线');
    expect(prompt.indexOf('讲解时先给结论'),
        greaterThan(prompt.indexOf(AIService.baseSystemPrompt)));
    ai.dispose();
  });

  test('插件模板任务：模板填槽后作为 user 消息发出，system 带插件风格', () async {
    writePlugin(
      'com.example.cheat',
      prompt: '小抄要写成表格。',
      templates: {
        'cheat_sheet.md': '根据下列错题生成小抄：\n{{ERROR_QUESTIONS}}',
      },
    );
    await PluginPromptService.instance
        .refresh(root: tmp, installed: [installed('com.example.cheat')]);

    final bodies = <Map<String, dynamic>>[];
    final ai = service(capturing(bodies));
    final out = await ai.runPluginTask(
      template: 'cheat_sheet',
      vars: const {'ERROR_QUESTIONS': '[1] 病理切片判断'},
    );

    expect(out, '依据错题生成的小抄');
    expect(bodies, hasLength(1));
    final messages = (bodies.single['messages'] as List).cast<Map>();
    expect(messages.first['role'], 'system');
    final system = messages.first['content'] as String;
    expect(system, contains('小抄要写成表格'));
    expect(system.startsWith(AIService.baseSystemPrompt), isTrue);
    final user = messages.last['content'] as String;
    expect(user, contains('[1] 病理切片判断'));
    expect(user.contains('{{ERROR_QUESTIONS}}'), isFalse);
    ai.dispose();
  });

  test('模板缺失：不发请求，直接给出可读提示（不静默换提示词）', () async {
    final bodies = <Map<String, dynamic>>[];
    final ai = service(capturing(bodies));
    final out = await ai.runPluginTask(template: 'cheat_sheet');

    expect(bodies, isEmpty, reason: '没有模板时不该浪费一次请求');
    expect(out, AIService.pluginTemplateMissingMessage('cheat_sheet'));
    expect(out, contains('prompts/cheat_sheet.md'));
    ai.dispose();
  });

  test('插件模板任务的流式版本：产出累计文本，最后一段是完整结果', () async {
    writePlugin(
      'com.example.cheat',
      prompt: '小抄要写成表格。',
      templates: {'cheat_sheet.md': '错题：{{ERROR_QUESTIONS}}'},
    );
    await PluginPromptService.instance
        .refresh(root: tmp, installed: [installed('com.example.cheat')]);

    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.bytesToString();
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

    final ai = service(client);
    final chunks = await ai
        .streamPluginTask(
          template: 'prompts/cheat_sheet.md',
          vars: const {'ERROR_QUESTIONS': '[1] 题目乙'},
        )
        .toList();
    expect(chunks.last, '结论先行');
    ai.dispose();
  });
}
