import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Google Gemini 提供方（v13 多接口）。
///
/// 原生实现 `generateContent` / `streamGenerateContent` 协议
/// （`x-goog-api-key` 认证）。system 消息走 `systemInstruction`，
/// 其余消息映射到 `contents`。
class GeminiProvider implements AiProvider {
  final AiProviderConfig _config;

  GeminiProvider(AiProviderConfig config) : _config = config;

  static const String defaultEndpoint =
      'https://generativelanguage.googleapis.com';

  String get _base {
    var b = _config.apiEndpoint.trim();
    if (b.isEmpty) b = defaultEndpoint;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Uri _url(String model, {required bool stream}) => Uri.parse(
      '$_base/v1beta/models/$model:${stream ? 'streamGenerateContent' : 'generateContent'}');

  Map<String, String> _headers() => {
        'content-type': 'application/json',
        'x-goog-api-key': _config.apiKey,
      };

  Map<String, dynamic> _body(AiChatRequest request) {
    final systemParts = [
      for (final m in request.messages.where((m) => m.role == 'system'))
        {'text': m.content},
    ];
    final contents = [
      for (final m in request.messages.where((m) => m.role != 'system'))
        {
          'role': m.role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': m.content},
          ],
        },
    ];
    return {
      if (systemParts.isNotEmpty) 'systemInstruction': {'parts': systemParts},
      'contents': contents,
      'generationConfig': {
        'temperature': request.temperature,
        if (request.maxTokens != null) 'maxOutputTokens': request.maxTokens,
      },
    };
  }

  String _extractText(Map<String, dynamic> data) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final first = candidates[0];
    if (first is! Map) return '';
    final content = first['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List) return '';
    return parts
        .whereType<Map>()
        .map((p) => p['text']?.toString() ?? '')
        .join('');
  }

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    final response = await _config.client
        .post(
          _url(request.model, stream: false),
          headers: _headers(),
          body: jsonEncode(_body(request)),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Gemini 服务返回错误 (${response.statusCode})');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return AiChatResponse(content: _extractText(data));
  }

  @override
  Stream<String> chatStream(AiChatRequest request) async* {
    final req = http.Request('POST', _url(request.model, stream: true))
      ..headers.addAll(_headers())
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode(_body(request));

    final response =
        await _config.client.send(req).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Gemini 服务返回错误 (${response.statusCode})');
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
      if (payload.isEmpty || payload == '[DONE]') continue;
      Map<String, dynamic> data;
      try {
        data = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final text = _extractText(data);
      if (text.isNotEmpty) {
        received = true;
        buffer.write(text);
        yield buffer.toString();
      }
    }
    if (!received) throw Exception('Gemini 流式响应为空');
  }

  @override
  void dispose() {
    // HTTP 客户端由上层 `AIService` 持有并负责关闭。
  }
}
