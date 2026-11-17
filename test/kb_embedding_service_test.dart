import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/services/api_endpoint.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_embedding_service.dart';

/// v1.43 Embeddings 客户端契约：端点推导、批量、失败回退、404 记忆。
void main() {
  const config = KbEmbeddingConfig(
    enabled: true,
    apiKey: 'test-key',
    apiEndpoint: 'https://api.openai.com/v1/chat/completions',
    model: 'text-embedding-3-small',
    providerKind: AiProviderKind.openaiCompat,
  );

  setUp(() => KbEmbeddingService.resetUnsupportedForTest());
  tearDown(() {
    KbEmbeddingService.instance.clientOverrideForTest = null;
    KbEmbeddingService.embedOverrideForTest = null;
  });

  test('端点推导：chat/completions → embeddings（保留版本段）', () {
    expect(
        ApiEndpoint.embeddingsUrl('https://api.openai.com/v1/chat/completions')
            .toString(),
        'https://api.openai.com/v1/embeddings');
    expect(
        ApiEndpoint.embeddingsUrl('https://api.siliconflow.cn/v1').toString(),
        'https://api.siliconflow.cn/v1/embeddings');
    expect(
        ApiEndpoint.embeddingsUrl(
                'https://opencode.ai/zen/go/v1/chat/completions')
            .toString(),
        'https://opencode.ai/zen/go/v1/embeddings');
  });

  test('批量请求：16 条以内分块，响应按 index 还原', () async {
    var hits = 0;
    KbEmbeddingService.instance.clientOverrideForTest = MockClient((req) async {
      hits++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(req.headers['Authorization'], 'Bearer test-key');
      expect(body['model'], 'text-embedding-3-small');
      final inputs = (body['input'] as List).cast<String>();
      return http.Response(
        jsonEncode({
          'data': [
            for (var i = 0; i < inputs.length; i++)
              {
                'index': i,
                'embedding': [i.toDouble(), inputs[i].length.toDouble()],
              }
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final vectors = await KbEmbeddingService.instance
        .embedAll(['a', 'bb', 'ccc'], config, batchSize: 2);
    expect(hits, 2);
    expect(vectors, hasLength(3));
    expect(vectors![0], [0.0, 1.0]);
    expect(vectors[1], [1.0, 2.0]);
    expect(vectors[2], [0.0, 3.0]);
  });

  test('未配置 Key / 关闭开关 / 不支持的供应商：直接返回 null（不发请求）', () async {
    var hits = 0;
    KbEmbeddingService.instance.clientOverrideForTest = MockClient((_) async {
      hits++;
      return http.Response('{}', 200);
    });
    expect(
        await KbEmbeddingService.instance
            .embedAll(['x'], config.copyWithKey('')),
        isNull);
    expect(
        await KbEmbeddingService.instance.embedAll(
            ['x'],
            const KbEmbeddingConfig(
              enabled: false,
              apiKey: 'k',
              apiEndpoint: 'https://api.openai.com/v1',
              model: 'm',
              providerKind: AiProviderKind.openaiCompat,
            )),
        isNull);
    expect(
        await KbEmbeddingService.instance.embedAll(
            ['x'],
            const KbEmbeddingConfig(
              enabled: true,
              apiKey: 'k',
              apiEndpoint: 'https://api.anthropic.com/v1',
              model: 'm',
              providerKind: AiProviderKind.anthropic,
            )),
        isNull);
    expect(hits, 0);
  });

  test('404 视为供应商不支持：后续同端点同模型不再重复请求', () async {
    var hits = 0;
    KbEmbeddingService.instance.clientOverrideForTest = MockClient((_) async {
      hits++;
      return http.Response('not found', 404);
    });
    expect(await KbEmbeddingService.instance.embedAll(['x'], config), isNull);
    expect(await KbEmbeddingService.instance.embedAll(['x'], config), isNull);
    expect(hits, 1, reason: '404 后应记住该端点不支持，避免每次导入都白跑');
  });

  test('响应结构不对 / 维度不一致：返回 null，回退 BM25', () async {
    KbEmbeddingService.instance.clientOverrideForTest = MockClient((_) async {
      return http.Response(jsonEncode({'data': []}), 200,
          headers: {'content-type': 'application/json'});
    });
    expect(await KbEmbeddingService.instance.embedAll(['x'], config), isNull);

    KbEmbeddingService.instance.clientOverrideForTest = MockClient((_) async {
      return http.Response(
          jsonEncode({
            'data': [
              {
                'index': 0,
                'embedding': [1.0, 2.0]
              },
              {
                'index': 1,
                'embedding': [1.0]
              },
            ]
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    expect(
        await KbEmbeddingService.instance.embedAll(['x', 'y'], config), isNull);
  });

  test('测试注入 embedOverrideForTest 优先于 HTTP', () async {
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async => [
          for (final _ in texts) [1.0, 0.0]
        ];
    final vectors =
        await KbEmbeddingService.instance.embedAll(['a', 'b'], config);
    expect(vectors, [
      [1.0, 0.0],
      [1.0, 0.0]
    ]);
  });
}

extension on KbEmbeddingConfig {
  KbEmbeddingConfig copyWithKey(String key) => KbEmbeddingConfig(
        enabled: enabled,
        apiKey: key,
        apiEndpoint: apiEndpoint,
        model: model,
        providerKind: providerKind,
      );
}
