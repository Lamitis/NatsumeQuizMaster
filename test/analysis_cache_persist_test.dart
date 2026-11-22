import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// v1.44「解析固定化」的契约：
///
/// 真机反馈「AI 解析出来之后二次进入又不见了，还得再解析一遍」。根因是
/// v1.43 及以前 `streamAnalysis` 只在 `grounding == null` 时读写缓存——只要
/// 用户导入过知识库并在解析时注入了资料，缓存通道就被整体绕过，每次点开
/// 解析都要重新检索 + 重新请求。
///
/// 现在约定：
/// ① 带知识库约束的解析**也要落缓存**；
/// ② 二次进入（哪怕仍带着 grounding）直接给缓存，**不发任何请求**；
/// ③ 缓存里保留「是否接地 / 详细程度 / 资料指纹」，界面据此打标；
/// ④ 只有 `forceRefresh`（用户手动「重新生成解析」）才重新请求。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_analysis_persist_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  http.StreamedResponse sse(List<String> pieces) => http.StreamedResponse(
        Stream.value(utf8.encode([
          for (final p in pieces)
            'data: ${jsonEncode({
              'choices': [
                {'delta': {'content': p}}
              ]
            })}',
          '',
          'data: [DONE]',
          '',
        ].join('\n'))),
        200,
        headers: {'content-type': 'text/event-stream'},
      );

  Future<Question> seedQuestion() async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankId =
        await db.insertBank(QuestionBank(name: '解析持久化题库', createdAt: now));
    await db.insertQuestions([
      Question(
        bankId: bankId,
        title: '休克的早期表现是什么？',
        options: const ['血压下降', '皮肤湿冷'],
        correctAnswer: 'B',
        createdAt: now,
      ),
    ]);
    final qs = await db.getQuestionsByBank(bankId);
    return qs.first;
  }

  test('带知识库约束的解析会落缓存，二次进入不再发请求；力刷才会重请求', () async {
    var requests = 0;
    final q = await seedQuestion();
    const grounding = '# 知识库参考资料\n【资料1】休克早期表现为皮肤湿冷、脉搏细速。';

    final svc = AIService(
      AppSettings(apiKey: 'sk-test', model: 'm'),
      client: MockClient.streaming((req, body) async {
        requests++;
        return sse(['休克早期', '表现为皮肤湿冷']);
      }),
    );

    final first = await svc.streamAnalysis(q, grounding: grounding).toList();
    expect(first.last, '休克早期表现为皮肤湿冷');
    expect(requests, 1, reason: '首次没有缓存，必须请求一次');

    // 模拟「二次进入题目」：仍然带着同样的 grounding
    final second = await svc.streamAnalysis(q, grounding: grounding).toList();
    expect(second, ['休克早期表现为皮肤湿冷'], reason: '应整段给出已保存的解析');
    expect(requests, 1, reason: '命中缓存时不得再发请求');

    // 元数据要能说明这条解析是怎么来的
    final entry = await DatabaseService.instance.getCachedAnalysisEntry(q.id!);
    expect(entry, isNotNull);
    expect(entry!.grounded, isTrue, reason: '界面据此打「依据知识库」标');
    expect(entry.detail, isNotNull);
    expect(entry.groundingSignature, isNotNull);

    // 只有手动「重新生成」才允许绕过缓存
    await svc.streamAnalysis(q, grounding: grounding, forceRefresh: true)
        .toList();
    expect(requests, 2, reason: 'forceRefresh 必须真的重新请求');
  });

  test('生成失败（错误串）不写缓存：下次点开还能重试', () async {
    var requests = 0;
    final q = await seedQuestion();
    final svc = AIService(
      AppSettings(apiKey: 'sk-test', model: 'm'),
      client: MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'error': {'message': 'boom'}
          }),
          500,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await svc.streamAnalysis(q, grounding: '【资料1】x').toList();
    expect(await DatabaseService.instance.getCachedAnalysisEntry(q.id!),
        isNull,
        reason: '错误串不能被当作解析缓存下来');

    await svc.streamAnalysis(q, grounding: '【资料1】x').toList();
    expect(requests, greaterThan(1), reason: '没有缓存时会再次尝试（不是永久失败）');
  });

  test('无知识库时指纹为空：不同题的「无资料」不会共用同一份指纹', () async {
    final q = await seedQuestion();
    final svc = AIService(
      AppSettings(apiKey: 'sk-test', model: 'm'),
      client: MockClient.streaming((req, body) async => sse(['无资料的解析'])),
    );
    await svc.streamAnalysis(q).toList();
    final entry = await DatabaseService.instance.getCachedAnalysisEntry(q.id!);
    expect(entry!.grounded, isFalse);
    expect(entry.groundingSignature, isNull);
  });
}
