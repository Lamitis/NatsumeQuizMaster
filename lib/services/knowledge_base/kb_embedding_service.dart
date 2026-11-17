import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../models/app_settings.dart';
import '../api_endpoint.dart';
import '../debug_log_service.dart';

/// 知识库向量化配置（从 [AppSettings] 投影而来）。
class KbEmbeddingConfig {
  const KbEmbeddingConfig({
    required this.enabled,
    required this.apiKey,
    required this.apiEndpoint,
    required this.model,
    required this.providerKind,
  });

  /// 从全局设置投影：与对话共用同一份 Key / 端点，用户只需填模型名。
  factory KbEmbeddingConfig.fromSettings(AppSettings settings) =>
      KbEmbeddingConfig(
        enabled: settings.kbVectorEnabled,
        apiKey: settings.apiKey,
        apiEndpoint: settings.apiEndpoint,
        model: settings.embeddingModel.trim().isEmpty
            ? AppSettings.defaultEmbeddingModel
            : settings.embeddingModel.trim(),
        providerKind: settings.providerKind,
      );

  final bool enabled;
  final String apiKey;
  final String apiEndpoint;
  final String model;
  final AiProviderKind providerKind;

  /// 当前供应商是否走 OpenAI 兼容 `/embeddings`。
  ///
  /// Anthropic 没有 embedding 接口；Gemini 走的是另一套 `:embedContent`，
  /// 这里不冒充支持——返回 false 会自然回退 BM25，不会把错误请求发出去。
  bool get supported =>
      providerKind == AiProviderKind.openaiCompat ||
      providerKind == AiProviderKind.ollama;

  /// 是否真的可以发请求：开关打开 + 供应商支持 + 有 Key（Ollama 本地免 Key）。
  bool get usable {
    if (!enabled || !supported || model.trim().isEmpty) return false;
    if (providerKind == AiProviderKind.ollama) return true;
    return apiKey.trim().isNotEmpty;
  }

  /// 存库用的键：模型 + 端点。
  ///
  /// 换端点后同名模型的维度/语义可能完全不同（例如 OpenAI 与本地 Ollama
  /// 都叫 `nomic-embed-text`），用复合键能保证「换端点 ⇒ 旧向量视为缺失、
  /// 自动重建」，而不是拿两套不兼容的向量算余弦。
  String get storageKey => '${model.trim()}@${apiEndpoint.trim()}';
}

/// 知识库向量化（Embedding）客户端（v1.43）。
///
/// 技术选型：
/// - **不引入 sqlite-vss**：sqflite 加载不了原生扩展，为 Android/Windows
///   各打一份 .so/.dll 成本高、还得自己维护；
/// - **不引入纯 Dart HNSW**：个人知识库通常几百到几千块，暴力余弦是
///   O(N·d)，几千块只需几毫秒，提前上 HNSW 只会增加复杂度；
/// - 因此走 **OpenAI 兼容 Embeddings 接口 + 本地 Float32 向量 + Dart 余弦**，
///   数据不出本机（除 Embedding 请求本身），离线/未配置时回退 BM25。
///
/// 任何失败都返回 null（不抛异常）：向量化是增强能力，不能阻断导入 /
/// 检索 / 导入流程；调用方拿到 null 就用关键词检索兜底。
class KbEmbeddingService {
  KbEmbeddingService._();
  static final KbEmbeddingService instance = KbEmbeddingService._();

  /// 默认模型：OpenAI / 多数聚合平台都支持；用户可在设置里改。
  static const String defaultModel = AppSettings.defaultEmbeddingModel;

  /// 已经确认不支持 `/embeddings` 的「端点+模型」组合：避免每次导入都白跑一趟
  /// （例如 DeepSeek 的 OpenAI 兼容接口目前没有 embedding 接口）。
  static final Set<String> _unsupported = {};

  @visibleForTesting
  static void resetUnsupportedForTest() => _unsupported.clear();

  static String _keyOf(KbEmbeddingConfig config) =>
      '${config.apiEndpoint.trim()}::${config.model.trim()}';

  /// 单次请求最多送多少块：批量能显著降低请求数，又不会撞到输入上限。
  static const int defaultBatchSize = 16;

  static const Duration timeout = Duration(seconds: 25);

  /// 测试注入：HTTP 客户端 / 直接返回向量的函数。
  http.Client? clientOverrideForTest;
  static Future<List<List<double>>?> Function(
      List<String> texts, KbEmbeddingConfig config)? embedOverrideForTest;

  /// 把若干文本转成向量；失败返回 null。
  Future<List<List<double>>?> embedAll(
    List<String> texts,
    KbEmbeddingConfig config, {
    int batchSize = defaultBatchSize,
  }) async {
    if (texts.isEmpty || !config.usable) return null;
    if (_unsupported.contains(_keyOf(config))) return null;
    final override = embedOverrideForTest;
    if (override != null) {
      final vectors = await override(texts, config);
      if (vectors == null || vectors.length != texts.length) return null;
      return vectors;
    }
    final out = <List<double>>[];
    final size = batchSize <= 0 ? defaultBatchSize : batchSize;
    for (var i = 0; i < texts.length; i += size) {
      final batch = texts.sublist(i, min(i + size, texts.length));
      final vectors = await _embedBatch(batch, config);
      if (vectors == null) return null;
      out.addAll(vectors);
    }
    return out;
  }

  /// 单条查询向量；失败返回 null（调用方回退 BM25）。
  Future<List<double>?> embedQuery(
      String text, KbEmbeddingConfig config) async {
    final result = await embedAll([text], config, batchSize: 1);
    if (result == null || result.isEmpty) return null;
    return result.first;
  }

  Future<List<List<double>>?> _embedBatch(
      List<String> batch, KbEmbeddingConfig config) async {
    final injected = clientOverrideForTest;
    final client = injected ?? http.Client();
    try {
      final response = await client
          .post(
            ApiEndpoint.embeddingsUrl(config.apiEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': ApiEndpoint.userAgent,
              if (config.apiKey.trim().isNotEmpty)
                'Authorization': 'Bearer ${config.apiKey.trim()}',
            },
            body: jsonEncode({
              'model': config.model,
              'input': batch,
            }),
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        // 404 说明该供应商没有 /embeddings：记下来，后续导入不再重复请求
        if (response.statusCode == 404) _unsupported.add(_keyOf(config));
        DebugLogService.instance.log('EMBED',
            '向量化失败 HTTP ${response.statusCode}: ${ApiEndpoint.explainStatus(response.statusCode, utf8.decode(response.bodyBytes, allowMalformed: true))}');
        return null;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final list = data is Map ? data['data'] : null;
      if (list is! List || list.length != batch.length) return null;
      final vectors = List<List<double>?>.filled(batch.length, null);
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map) return null;
        final embedding = item['embedding'];
        if (embedding is! List || embedding.isEmpty) return null;
        final rawIndex = item['index'];
        final index =
            (rawIndex is int && rawIndex >= 0 && rawIndex < batch.length)
                ? rawIndex
                : i;
        vectors[index] = [
          for (final v in embedding)
            if (v is num) v.toDouble() else 0.0,
        ];
      }
      if (vectors.any((v) => v == null || v.isEmpty)) return null;
      final dim = vectors.first!.length;
      if (vectors.any((v) => v!.length != dim)) return null;
      return [for (final v in vectors) v!];
    } catch (e) {
      DebugLogService.instance.log('EMBED', '向量化请求失败：$e');
      return null;
    } finally {
      if (injected == null) client.close();
    }
  }
}
