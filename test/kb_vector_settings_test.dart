import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_embedding_service.dart';

/// v1.43 知识库向量化设置：
/// 默认开启、随备份往返、老备份兼容，以及「什么时候才真的发 Embedding 请求」。
void main() {
  test('默认开启向量化，默认模型为 text-embedding-3-small', () {
    expect(AppSettings().kbVectorEnabled, isTrue);
    expect(AppSettings().embeddingModel, 'text-embedding-3-small');
    // 老备份没有这两个键 → 开启 + 默认模型（不支持时会自动回退 BM25）
    final old = AppSettings.fromMap(const {});
    expect(old.kbVectorEnabled, isTrue);
    expect(old.embeddingModel, 'text-embedding-3-small');
  });

  test('toMap / fromMap 往返保留关闭状态与自定义模型', () {
    final settings = AppSettings().copyWith(
      kbVectorEnabled: false,
      embeddingModel: 'BAAI/bge-m3',
    );
    final map = settings.toMap();
    expect(map['kb_vector_enabled'], '0');
    expect(map['embedding_model'], 'BAAI/bge-m3');
    final back = AppSettings.fromMap(map);
    expect(back.kbVectorEnabled, isFalse);
    expect(back.embeddingModel, 'BAAI/bge-m3');
  });

  test('空白模型名回落到默认值（避免发出 model="" 的请求）', () {
    expect(AppSettings.fromMap(const {'embedding_model': '  '}).embeddingModel,
        AppSettings.defaultEmbeddingModel);
    expect(
        KbEmbeddingConfig.fromSettings(AppSettings(embeddingModel: '  ')).model,
        AppSettings.defaultEmbeddingModel);
  });

  test('存储键包含模型 + 端点：换端点后旧向量视为缺失', () {
    const a = KbEmbeddingConfig(
      enabled: true,
      apiKey: 'k',
      apiEndpoint: 'https://api.openai.com/v1',
      model: 'nomic-embed-text',
      providerKind: AiProviderKind.openaiCompat,
    );
    const b = KbEmbeddingConfig(
      enabled: true,
      apiKey: 'k',
      apiEndpoint: 'http://localhost:11434/v1',
      model: 'nomic-embed-text',
      providerKind: AiProviderKind.ollama,
    );
    expect(a.storageKey, isNot(b.storageKey));
    expect(a.storageKey, contains('nomic-embed-text'));
    expect(a.storageKey, contains('api.openai.com'));
  });

  test('usable：开关 + 供应商支持 + Key（Ollama 免 Key）', () {
    KbEmbeddingConfig config({
      bool enabled = true,
      String key = 'k',
      AiProviderKind kind = AiProviderKind.openaiCompat,
    }) =>
        KbEmbeddingConfig(
          enabled: enabled,
          apiKey: key,
          apiEndpoint: 'https://api.example.com/v1',
          model: 'm',
          providerKind: kind,
        );

    expect(config().usable, isTrue);
    expect(config(enabled: false).usable, isFalse);
    expect(config(key: '').usable, isFalse);
    expect(config(kind: AiProviderKind.anthropic).usable, isFalse);
    expect(config(kind: AiProviderKind.gemini).usable, isFalse);
    expect(config(kind: AiProviderKind.ollama, key: '').usable, isTrue);
  });
}
