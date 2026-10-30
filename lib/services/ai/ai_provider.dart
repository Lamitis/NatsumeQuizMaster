import 'package:http/http.dart' as http;

/// AI 提供方抽象（v13 多接口）。
///
/// 把「和模型服务商对话」这件事收敛成一个最小接口：`chat`（一次性）与
/// `chatStream`（流式，产出累计全文）。各提供方（OpenAI 兼容 / Anthropic /
/// Gemini / Ollama）实现各自协议；上层 `AIService` 只按
/// `AppSettings.providerKind` 选一个转发，不再关心协议差异。
///
/// 注意：`listModels` / `testConnection` / `fetchBalance` / DOCX-PDF 解析
/// （`response_format: json_object` + 视觉）是 OpenAI 兼容协议专属能力，
/// 仍由 `AIService` 直接走 `OpenAiCompatProvider`，不放进本接口。

/// 一条对话消息。
class AiMessage {
  final String role; // 'system' | 'user' | 'assistant'
  final String content;

  const AiMessage(this.role, this.content);

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// 一次对话请求。
class AiChatRequest {
  final String model;
  final List<AiMessage> messages;
  final double temperature;
  final int? maxTokens;

  const AiChatRequest({
    required this.model,
    required this.messages,
    this.temperature = 0.3,
    this.maxTokens,
  });
}

/// 一次对话响应（非流式）。
class AiChatResponse {
  final String content;
  final int totalTokens;

  const AiChatResponse({required this.content, this.totalTokens = 0});
}

/// 提供方配置：密钥、基址、模型名、会话标识（供应商专用头用）、HTTP 客户端。
class AiProviderConfig {
  final String apiKey;
  final String apiEndpoint;
  final String model;
  final String sessionId;
  final http.Client client;

  const AiProviderConfig({
    required this.apiKey,
    required this.apiEndpoint,
    required this.model,
    required this.sessionId,
    required this.client,
  });
}

/// AI 提供方接口。
abstract class AiProvider {
  /// 非流式对话。
  Future<AiChatResponse> chat(AiChatRequest request);

  /// 流式对话：每次 `yield` 给出**到目前为止的累计全文**（调用方直接赋值）。
  Stream<String> chatStream(AiChatRequest request);

  void dispose();
}
