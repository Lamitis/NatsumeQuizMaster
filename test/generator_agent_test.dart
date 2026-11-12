import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';
import 'package:natsume_quiz_master/services/question_generator/generator_agent.dart';

/// 自动出题的容错（v1.41.4）。
///
/// 真机反馈：AI 连续检索知识库后，最后一步 `write_question_bank` 传了空内容
/// （或参数被截断），旧实现直接抛「json 为空，请提供题目 JSON」，整次生成报废。
/// 现在的契约：
/// 1. 空 / 非法 JSON 只是**工具返回纠错提示**，不中断循环；
/// 2. 一整轮都没写出题 → 带纠错提示重试一轮；
/// 3. 分批调用 write_question_bank 时**追加合并**，不会互相覆盖；
/// 4. 真的没生成出来时返回可读的 failureReason 给 UI。
void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('natsume_gen_');
  });

  tearDown(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  http.Response chatResponse({
    List<Map<String, dynamic>>? toolCalls,
    String? content,
  }) {
    return http.Response.bytes(
      utf8.encode(jsonEncode({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              if (content != null) 'content': content,
              if (toolCalls != null) 'tool_calls': toolCalls,
            },
          }
        ],
      })),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  /// 一次 write_question_bank 调用；[jsonArg] 就是工具参数里的 json 字符串
  Map<String, dynamic> writeCall(String id, String jsonArg) => {
        'id': id,
        'type': 'function',
        'function': {
          'name': 'write_question_bank',
          'arguments': jsonEncode({'json': jsonArg}),
        },
      };

  String questionsJson(int from, int to) => jsonEncode({
        'questions': [
          for (var i = from; i <= to; i++)
            {
              'title': '题目 $i',
              'options': ['甲', '乙', '丙', '丁'],
              'correct_answer': 'A',
              'question_type': 'single_choice',
              'analysis': '解析 $i',
              'knowledge_point': '心血管生理',
            },
        ],
      });

  GeneratorAgent agent(http.Client client) => GeneratorAgent(
        aiService: AIService(
          AppSettings(apiKey: 'sk-test', model: 'test-model'),
          client: client,
        ),
        kbService: KbService.instance,
      );

  test('AI 先给空 JSON：工具回纠错提示，下一轮写成功，整次生成不中断', () async {
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      calls++;
      switch (calls) {
        case 1:
          // 第一轮：空 JSON（真机上就是这个把生成打死的）
          return chatResponse(toolCalls: [writeCall('c1', '')]);
        case 2:
          return chatResponse(toolCalls: [writeCall('c2', questionsJson(1, 2))]);
        default:
          return chatResponse(content: '完成');
      }
    });

    final result = await agent(client).generate(
      kbId: 1,
      targetCount: 2,
      bankName: '生成题库',
      sandboxDir: sandbox,
    );

    expect(result.questionCount, 2);
    expect(result.failureReason, isNull);
    expect(result.log.join('\n'), contains('json 为空'));
    final file = File('${sandbox.path}/questions.json');
    expect(file.existsSync(), isTrue);
    expect(
      ((jsonDecode(file.readAsStringSync()) as Map)['questions'] as List).length,
      2,
    );
    expect(bodies, hasLength(3));
  });

  test('分批写入：两次调用按题干去重后追加合并，前一批不被覆盖', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return chatResponse(toolCalls: [
          writeCall('b1', questionsJson(1, 2)),
          writeCall('b2', questionsJson(2, 4)), // 与上一批重叠 1 道
        ]);
      }
      return chatResponse(content: '完成');
    });

    final result = await agent(client).generate(
      kbId: 1,
      targetCount: 4,
      bankName: '分批题库',
      sandboxDir: sandbox,
    );

    expect(result.questionCount, 4, reason: '重叠的「题目 2」只保留一份');
    expect(result.log.join('\n'), contains('累计 4 道'));
  });

  test('整轮都拿不到有效 JSON：带纠错提示重试一轮，仍失败则给出可读原因', () async {
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      calls++;
      // 每轮：先空 JSON，再收尾（不调工具），让循环尽快进到重试判定
      return calls.isOdd
          ? chatResponse(toolCalls: [writeCall('e$calls', '')])
          : chatResponse(content: '我不知道');
    });

    final result = await agent(client).generate(
      kbId: 1,
      targetCount: 3,
      bankName: '失败题库',
      sandboxDir: sandbox,
    );

    expect(result.questionCount, 0);
    expect(result.failureReason, isNotNull);
    expect(result.log.join('\n'), contains('重试'));
    // 第二次发问里必须带上纠错提示（而不是原样再问一遍）
    expect(bodies.length, greaterThanOrEqualTo(3));
    final third = jsonEncode(bodies[2]);
    expect(third, contains('上一次的 write_question_bank'));
    expect(third, contains('绝不允许空 JSON'));
  });

  group('工具参数解析', () {
    test('正常参数：取出 json 字符串', () {
      final args = GeneratorAgent.decodeToolArguments(
          jsonEncode({'json': questionsJson(1, 1)}));
      expect(args['json'], isA<String>());
      expect(args['json'], contains('题目 1'));
    });

    test('参数被截断：不抛异常，退回空 map（交给纠错提示）', () {
      const truncated = '{"json": "{\\"questions\\":[{\\"title\\":\\"题目 1\\"';
      final args = GeneratorAgent.decodeToolArguments(truncated);
      expect(args, isEmpty);
    });

    test('参数不是 JSON：正则抠出 json 字段的字符串', () {
      final inner = questionsJson(1, 1).replaceAll('"', r'\"');
      final args = GeneratorAgent.decodeToolArguments('noise {"json": "$inner"}');
      expect(args['json'], isA<String>());
      expect(args['json'], contains('题目 1'));
    });

    test('截断的题目 JSON：抢救已完整的题目', () {
      final payload = GeneratorAgent.parsePayload(
          '{"questions":[{"title":"Q1","correct_answer":"A"},{"title":"Q2"');
      final qs = GeneratorAgent.questionsOf(payload);
      expect(qs, hasLength(1));
      expect(qs.single['title'], 'Q1');
    });

    test('带 Markdown 围栏的 JSON 也能解析', () {
      final payload =
          GeneratorAgent.parsePayload('```json\n${questionsJson(1, 1)}\n```');
      expect(GeneratorAgent.questionsOf(payload), hasLength(1));
    });
  });
}
