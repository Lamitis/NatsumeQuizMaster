import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Anthropic Messages API 提供方（v13 多接口）。
///
/// 原生实现 `/v1/messages` 协议（`x-api-key` + `anthropic-version`）。
/// 支持非流式与 SSE 流式（`content_block_delta` 增量），累计产出全文。
class AnthropicProvider implements AiProvider {
  final AiProviderConfig _config;

  AnthropicProvider(AiProviderConfig config) : _config = config;

  static const String defaultEndpoint = 'https://api.anthropic.com';

  String get _messagesUrl {
    final base = _config.apiEndpoint.trim().isEmpty
        ? defaultEndpoint
        : _config.apiEndpoint.trim();
    if (base.endsWith('/v1/messages')) return base;
    if (base.endsWith('/')) return '${base}v1/messages';
    return '$base/v1/messages';
  }

  Map<String, String> _headers() => {
        'content-type': 'application/json',
        'x-api-key': _config.apiKey,
        'anthropic-version': '2023-06-01',
      };

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    final system = request.messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    final messages = [
      for (final m in request.messages.where((m) => m.role != 'system'))
        {'role': m.role, 'content': m.content},
    ];

    final response = await _config.client
        .post(
          Uri.parse(_messagesUrl),
          headers: _headers(),
          body: jsonEncode({
            'model': request.model,
            'max_tokens': request.maxTokens ?? 4096,
            if (system.isNotEmpty) 'system': system,
            'messages': messages,
            'temperature': request.temperature,
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Anthropic 服务返回错误 (${response.statusCode})');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final blocks = data['content'];
    final text = blocks is List
        ? blocks
            .whereType<Map>()
            .where((b) => b['type'] == 'text')
            .map((b) => b['text']?.toString() ?? '')
            .join('')
        : '';
    final usage = data['usage'];
    final total = usage is Map ? (usage['output_tokens'] as int?) ?? 0 : 0;
    return AiChatResponse(content: text, totalTokens: total);
  }

  @override
  Stream<String> chatStream(AiChatRequest request) async* {
    final system = request.messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    final messages = [
      for (final m in request.messages.where((m) => m.role != 'system'))
        {'role': m.role, 'content': m.content},
    ];

    final req = _config.client
        .send(await _httpRequest(request, system, messages, stream: true))
        .timeout(const Duration(seconds: 30));

    final response = await req;
    if (response.statusCode != 200) {
      throw Exception('Anthropic 服务返回错误 (${response.statusCode})');
    }

    final buffer = StringBuffer();
    var received = false;
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(seconds: 60));
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      Map<String, dynamic> data;
      try {
        data = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final type = data['type'] as String?;
      if (type == 'content_block_delta') {
        final delta = data['delta'];
        final text = delta is Map ? delta['text']?.toString() ?? '' : '';
        if (text.isNotEmpty) {
          received = true;
          buffer.write(text);
          yield buffer.toString();
        }
      } else if (type == 'message_stop') {
        break;
      }
    }
    if (!received) throw Exception('Anthropic 流式响应为空');
  }

  Future<http.Request> _httpRequest(
    AiChatRequest request,
    String system,
    List<Map<String, String>> messages, {
    required bool stream,
  }) async {
    final req = http.Request('POST', Uri.parse(_messagesUrl))
      ..headers.addAll(_headers())
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': request.model,
        'max_tokens': request.maxTokens ?? 4096,
        if (system.isNotEmpty) 'system': system,
        'messages': messages,
        'temperature': request.temperature,
        'stream': stream,
      });
    return req;
  }

  @override
  void dispose() {
    // HTTP 客户端由上层 `AIService` 持有并负责关闭，这里不做资源释放。
  }
}
