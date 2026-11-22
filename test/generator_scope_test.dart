import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';
import 'package:natsume_quiz_master/services/question_generator/generator_agent.dart';

/// v1.44 出题范围 / 题型 / 数量的接线契约。
///
/// 需求原话是「可针对某个知识库的某个或者某几个文件出题，题目种类可自定义，
/// 题目数量可自定义」。这三件事最终都要落进**提示词**才有用——只改 UI 不改
/// 提示词，AI 依然会拿整个知识库的资料出题、依然只出单选。
void main() {
  late Directory tmp;
  late Directory sandbox;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_gen_scope_db_');
    sandbox = Directory.systemTemp.createTempSync('natsume_gen_scope_');
    DatabaseService.overrideDbPath = '${tmp.path}/t.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    for (final d in [tmp, sandbox]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  http.Response chatResponse({String? content}) => http.Response.bytes(
        utf8.encode(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': content ?? '完成'}
            }
          ],
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  test('提示词里带出题范围 / 题型 / 数量；read_document 只认范围内的文档', () async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance.createKnowledgeBase('范围测试库');
    final docA = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '第一章 心血管.md',
      content: '心脏泵血功能由心肌收缩力决定。',
      createdAt: '2026-11-20T00:00:00.000',
    ));
    await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '第二章 呼吸.md',
      content: '肺泡通气与血流比例影响换气效率。',
      createdAt: '2026-11-20T00:00:00.000',
    ));

    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return chatResponse();
    });

    final agent = GeneratorAgent(
      aiService: AIService(
        AppSettings(apiKey: 'sk-test', model: 'test-model'),
        client: client,
      ),
      kbService: KbService.instance,
    );

    final result = await agent.generate(
      kbId: kbId,
      targetCount: 3,
      bankName: '范围题库',
      documentIds: [docA],
      documentNames: ['第一章 心血管.md'],
      questionTypes: ['true_false', 'fill_blank'],
      sandboxDir: sandbox,
    );

    // 没写出题库 → 过程日志里要有「出题范围」这一行（用户能看见自己选了范围）
    expect(result.log.join('\n'), contains('出题范围：1 篇指定文档'));
    expect(result.log.join('\n'), contains('第一章 心血管.md'));

    final system = (bodies.first['messages'] as List).first['content']
        .toString();
    expect(system, contains('第一章 心血管.md'), reason: '提示词要说清只出这几篇');
    expect(system, contains('仅限'), reason: '必须明确「范围外资料不得使用」');
    expect(system, contains('true_false（判断题）'), reason: '题型要落成中文名 + 存库值');
    expect(system, contains('fill_blank（填空题）'));
    expect(system, contains('只出 '), reason: '限定题型时不能再说「自行搭配」');
    expect(system, contains('3 道'), reason: '数量要写进提示词');
    // 范围外那篇不能在提示词里出现
    expect(system.contains('第二章 呼吸.md'), isFalse);
  });

  test('不选范围/题型时回到旧行为（整个知识库 + 自行搭配）', () async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance.createKnowledgeBase('全库测试库');
    await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '任意文档.md',
      content: '任意内容。',
      createdAt: '2026-11-20T00:00:00.000',
    ));

    final bodies = <Map<String, dynamic>>[];
    final agent = GeneratorAgent(
      aiService: AIService(
        AppSettings(apiKey: 'sk-test', model: 'test-model'),
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return chatResponse();
        }),
      ),
      kbService: KbService.instance,
    );

    await agent.generate(
      kbId: kbId,
      targetCount: 5,
      bankName: '全库题库',
      sandboxDir: sandbox,
    );

    final system = (bodies.first['messages'] as List).first['content']
        .toString();
    expect(system, contains('整个知识库'));
    expect(system, contains('自行搭配'));
    expect(system, contains('5 道'));
  });
}
