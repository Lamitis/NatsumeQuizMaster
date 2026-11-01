import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

/// 一个「候选源」：给人看的名字 + 实际要请求的 URL。
@immutable
class SmartSource {
  const SmartSource(this.label, this.url);

  final String label;
  final String url;

  @override
  bool operator ==(Object other) => other is SmartSource && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => '$label（$url）';
}

/// 单次尝试的记录。
///
/// 全部源都失败时不能让用户只看到一句「下载失败」——到底是被墙、镜像 502，
/// 还是镜像把包改坏了，得能说清楚。这里保留每个源的状态码与原因。
@immutable
class SmartAttempt {
  const SmartAttempt({
    required this.label,
    required this.url,
    this.statusCode,
    this.error,
  });

  final String label;
  final String url;
  final int? statusCode;

  /// null 表示这次是成功的；否则是失败原因（超时 / 非 200 / sha256 不匹配…）
  final String? error;

  bool get ok => error == null;

  String get summary {
    if (ok) return '$label：成功';
    final parts = <String>[
      if (statusCode != null) 'HTTP $statusCode',
      if (error != null) error!,
    ];
    return '$label：${parts.join(' · ')}';
  }
}

/// 多源请求的结果：字节 + 命中的源 + 之前失败的尝试。
class SmartHttpResult {
  const SmartHttpResult({
    required this.bytes,
    required this.url,
    required this.label,
    this.attempts = const [],
  });

  final List<int> bytes;

  /// 真正命中的 URL（可能带加速前缀）
  final String url;

  /// 命中源的名字（`原始` / `jsDelivr` / `加速·ghfast.top` / `自定义镜像`）
  final String label;

  final List<SmartAttempt> attempts;

  /// 按 UTF-8 解码（容错：镜像偶尔塞回一两个坏字节，不该让整张表作废）
  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// 多源请求全部失败。
///
/// [originalUrl] 是**未经加速的原始地址**：UI 可以把它复制给用户，让用户去
/// 浏览器手动下载，再用「本地安装」导入（彻底断网时的兜底路径）。
class SmartHttpException implements Exception {
  const SmartHttpException(
    this.message, {
    this.attempts = const [],
    this.originalUrl,
  });

  final String message;
  final List<SmartAttempt> attempts;
  final String? originalUrl;

  @override
  String toString() => message;
}

/// 全局网络客户端（v1.36）：国内直连 GitHub 经常超时，所有「拿插件」的请求
/// 都从这里走。
///
/// 三条约束写在最前面，后续加镜像时别踩：
/// - **顺序即优先级**：显式给出的自定义镜像 → 原始地址 → 内置加速池；
///   `registry.json` 另有一条 jsDelivr（它不是 GitHub 前缀式加速）。
/// - **单个源超时**：登记表 8 秒；超时 / 非 200 / 内容校验失败都只换下一个源，
///   不抛到 UI；全部失败才抛 [SmartHttpException]，并带上每个源的原因。
/// - **校验是逐源做的**：插件包无论从哪个镜像来，都必须与登记表里的 sha256
///   一致，不一致就丢弃该镜像的响应（绝不「先装再验」）。
///
/// 信任边界（重要）：sha256 只能证明「下载到的字节与登记表一致」，登记表本身
/// 仍是从 GitHub / 第三方镜像取回的明文 JSON，没有签名。镜像能加速，也能
/// 篡改登记表；这里的定位是**传输加速**，不是新的信任根。
class SmartHttpClient {
  SmartHttpClient({http.Client? client, String customMirror = ''})
      : _client = client,
        _customMirror = normalizeCustomMirror(customMirror);

  /// 全局单例：自定义镜像由 `AppState` 在加载/保存设置时同步进来
  static final SmartHttpClient instance = SmartHttpClient();

  static const String userAgent = 'NatsumeQuizMaster';

  /// 登记表单源超时（v1.36 规格：8 秒）
  static const Duration defaultTimeout = Duration(seconds: 8);

  /// 插件包下载单源超时。比登记表宽：几十 MB 的包在弱网下 8 秒必然误判。
  static const Duration defaultDownloadTimeout = Duration(seconds: 30);

  /// 自定义镜像在 settings 表里的键（与 `AppSettings` 的字段同名）
  static const String customMirrorSettingKey = 'custom_mirror';

  static const String registryRawUrl =
      'https://raw.githubusercontent.com/Lamitis/Natsume-Registry/main/registry.json';

  static const String registryJsDelivrUrl =
      'https://cdn.jsdelivr.net/gh/Lamitis/Natsume-Registry@main/registry.json';

  /// Release 下载加速前缀（顺序即回退顺序）。只对 GitHub 链接生效。
  static const List<String> acceleratorPrefixes = [
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://gh.llkk.cc/',
    'https://ghproxy.net/',
  ];

  /// 登记表候选池：原始 → jsDelivr → 4 个加速源。
  static const List<SmartSource> registrySources = [
    SmartSource('原始', registryRawUrl),
    SmartSource('jsDelivr', registryJsDelivrUrl),
    SmartSource(
      '加速1 ghfast.top',
      'https://ghfast.top/https://raw.githubusercontent.com/Lamitis/Natsume-Registry/main/registry.json',
    ),
    SmartSource(
      '加速2 gh-proxy.com',
      'https://gh-proxy.com/https://raw.githubusercontent.com/Lamitis/Natsume-Registry/main/registry.json',
    ),
    SmartSource(
      '加速3 gh.llkk.cc',
      'https://gh.llkk.cc/https://raw.githubusercontent.com/Lamitis/Natsume-Registry/main/registry.json',
    ),
    SmartSource(
      '加速4 ghproxy.net',
      'https://ghproxy.net/https://raw.githubusercontent.com/Lamitis/Natsume-Registry/main/registry.json',
    ),
  ];

  /// 拉 JSON 时统一带的头：GitHub 不给 User-Agent 会直接 403。
  static const Map<String, String> jsonHeaders = {
    'Accept': 'application/json',
    'User-Agent': userAgent,
  };

  final http.Client? _client;
  String _customMirror;

  /// 用户自定义镜像（空前缀 = 只用内置池）。赋值时会走
  /// [normalizeCustomMirror] 的规范化口径。
  String get customMirror => _customMirror;

  set customMirror(String value) =>
      _customMirror = normalizeCustomMirror(value);

  /// 统一格式：空白 → 空串；含 `{url}` 视为模板原样保留；否则当成前缀并补 `/`。
  static String normalizeCustomMirror(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    if (s.contains('{url}')) return s;
    return s.endsWith('/') ? s : '$s/';
  }

  /// 把自定义镜像套到某个原始地址上；空配置返回 null。
  ///
  /// 支持两种写法：
  /// - 前缀：`https://ghfast.top/`（自动补尾斜杠）
  /// - 模板：`https://my.proxy/?url={url}`（`{url}` 会被 URL 编码后替换）
  static String? applyCustomMirror(String raw, String originalUrl) {
    final mirror = normalizeCustomMirror(raw);
    if (mirror.isEmpty) return null;
    if (mirror.contains('{url}')) {
      return mirror.replaceAll('{url}', Uri.encodeComponent(originalUrl));
    }
    return '$mirror$originalUrl';
  }

  /// 登记表候选池（自定义镜像优先）。
  static List<SmartSource> registryCandidates({String? customMirror}) {
    final custom = applyCustomMirror(customMirror ?? '', registryRawUrl);
    return _dedupe([
      if (custom != null) SmartSource('自定义镜像', custom),
      ...registrySources,
    ]);
  }

  /// Release 下载候选池：自定义镜像 → 原始 → 4 个加速前缀。
  ///
  /// 非 GitHub 的 URL 只返回原始地址（加速前缀只代理 GitHub，套到别处只会 404）。
  static List<SmartSource> downloadCandidates(
    String originalUrl, {
    String? customMirror,
  }) {
    final custom = applyCustomMirror(customMirror ?? '', originalUrl);
    final out = <SmartSource>[
      if (custom != null) SmartSource('自定义镜像', custom),
      SmartSource('原始', originalUrl),
      if (isGitHubUrl(originalUrl))
        for (final prefix in acceleratorPrefixes)
          SmartSource('加速·${Uri.parse(prefix).host}', '$prefix$originalUrl'),
    ];
    return _dedupe(out);
  }

  /// 是否是会被加速池代理的 GitHub 链接
  static bool isGitHubUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return host == 'github.com' ||
        host == 'api.github.com' ||
        host == 'raw.githubusercontent.com' ||
        host.endsWith('.githubusercontent.com') ||
        host == 'codeload.github.com';
  }

  /// 拉 `registry.json`：逐源尝试，第一个 200 **且正文像 JSON** 的返回。
  Future<SmartHttpResult> fetchRegistry({
    Duration timeout = defaultTimeout,
    String? customMirror,
    Map<String, String>? headers,
  }) {
    return getFirst(
      registryCandidates(customMirror: customMirror ?? _customMirror),
      timeout: timeout,
      headers: headers ?? jsonHeaders,
      originalUrl: registryRawUrl,
      failurePrefix: '插件登记表读取失败',
      validate: looksLikeJson,
    );
  }

  /// 轻量格式探测：镜像被墙时经常返回 **200 的 HTML 拦截页**，
  /// 只看状态码会误判成「拉到了」，接着解析报 FormatException，
  /// 后面的源就再也没机会试了。
  static bool looksLikeJson(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true).trimLeft().startsWith('{');

  /// 下载插件包并**逐源校验 sha256**。
  ///
  /// 任一源返回 200 但哈希不一致 → 丢弃该响应、继续下一个源。全部失败抛
  /// [SmartHttpException]（带原始下载地址，供 UI 引导手动下载）。
  Future<SmartHttpResult> downloadVerified({
    required String url,
    required String expectedSha256,
    Duration timeout = defaultDownloadTimeout,
    String? customMirror,
    Map<String, String>? headers,
  }) async {
    final candidates =
        downloadCandidates(url, customMirror: customMirror ?? _customMirror);
    final expected = expectedSha256.trim().toLowerCase();
    final attempts = <SmartAttempt>[];

    for (final source in candidates) {
      try {
        final resp = await _get(source.url, timeout: timeout, headers: headers);
        if (resp.statusCode != 200) {
          attempts.add(SmartAttempt(
            label: source.label,
            url: source.url,
            statusCode: resp.statusCode,
            error: '非 200，换下一个源',
          ));
          continue;
        }
        final bytes = resp.bodyBytes;
        final hex = sha256.convert(bytes).toString();
        if (hex != expected) {
          attempts.add(SmartAttempt(
            label: source.label,
            url: source.url,
            statusCode: 200,
            error: 'sha256 不匹配，已丢弃',
          ));
          continue;
        }
        attempts.add(SmartAttempt(
          label: source.label,
          url: source.url,
          statusCode: 200,
        ));
        return SmartHttpResult(
          bytes: bytes,
          url: source.url,
          label: source.label,
          attempts: attempts,
        );
      } on TimeoutException {
        attempts.add(SmartAttempt(
          label: source.label,
          url: source.url,
          error: '超时（${timeout.inSeconds}s）',
        ));
      } catch (e) {
        attempts.add(SmartAttempt(
          label: source.label,
          url: source.url,
          error: '$e',
        ));
      }
    }

    throw SmartHttpException(
      '插件包下载失败：${candidates.length} 个源都不可用'
      '（超时 / 非 200 / 校验不通过）',
      attempts: attempts,
      originalUrl: url,
    );
  }

  /// 按顺序取第一个 200 的源，正文原样返回。
  ///
  /// [validate] 用来挡住「200 但内容不对」的响应（被墙时常见 HTML 拦截页）；
  /// 校验不过只算这个源失败，继续下一个。
  /// 单个源失败只记一条 [SmartAttempt]，不影响后续源；全部失败才抛
  /// [SmartHttpException]。
  Future<SmartHttpResult> getFirst(
    List<SmartSource> candidates, {
    required Duration timeout,
    Map<String, String>? headers,
    String? originalUrl,
    String failurePrefix = '请求失败',
    bool Function(List<int> bytes)? validate,
  }) async {
    final attempts = <SmartAttempt>[];
    for (final source in candidates) {
      try {
        final resp = await _get(source.url, timeout: timeout, headers: headers);
        if (resp.statusCode == 200) {
          if (validate != null && !validate(resp.bodyBytes)) {
            attempts.add(SmartAttempt(
              label: source.label,
              url: source.url,
              statusCode: 200,
              error: '内容格式不对（疑似拦截页），换下一个源',
            ));
            continue;
          }
          attempts.add(SmartAttempt(
            label: source.label,
            url: source.url,
            statusCode: 200,
          ));
          return SmartHttpResult(
            bytes: resp.bodyBytes,
            url: source.url,
            label: source.label,
            attempts: attempts,
          );
        }
        attempts.add(SmartAttempt(
          label: source.label,
          url: source.url,
          statusCode: resp.statusCode,
          error: '非 200，换下一个源',
        ));
      } on TimeoutException {
        attempts.add(SmartAttempt(
          label: source.label,
          url: source.url,
          error: '超时（${timeout.inSeconds}s）',
        ));
      } catch (e) {
        attempts.add(SmartAttempt(
          label: source.label,
          url: source.url,
          error: '$e',
        ));
      }
    }

    final detail = attempts.map((a) => a.summary).join('；');
    throw SmartHttpException(
      '$failurePrefix（已尝试 ${candidates.length} 个源）：$detail',
      attempts: attempts,
      originalUrl: originalUrl,
    );
  }

  /// 真正发请求的地方。没注入 client 时每次新建并关闭，避免连接池长期占用；
  /// 注入了就交给调用方管理生命周期（测试 / 复用连接）。
  Future<http.Response> _get(
    String url, {
    required Duration timeout,
    Map<String, String>? headers,
  }) {
    final uri = Uri.parse(url);
    final injected = _client;
    if (injected != null) {
      return injected.get(uri, headers: headers).timeout(timeout);
    }
    final own = http.Client();
    return own
        .get(uri, headers: headers)
        .timeout(timeout)
        .whenComplete(own.close);
  }

  static List<SmartSource> _dedupe(List<SmartSource> list) {
    final seen = <String>{};
    return [
      for (final source in list)
        if (seen.add(source.url)) source,
    ];
  }
}
