import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_constants.dart';
import 'net/smart_http_client.dart';

/// 检查更新的结果状态。
enum UpdateStatus { updateAvailable, upToDate, failed }

/// 检查更新结果（纯数据，方便测试直接断言）。
class UpdateCheckResult {
  final UpdateStatus status;

  /// 当前 App 主版本（[kAppVersion]，形如 `v1.35.5`；构建号见 `kAppBuildNumber`）
  final String currentVersion;

  /// 远端最新 tag（拿不到时为 null）
  final String? latestVersion;

  /// 下载页 / 资产直链（拿不到时为 null）
  final String? downloadUrl;

  /// 资产文件名（GitHub API 给到时才有；用于保存到缓存的命名）
  final String? downloadFileName;

  /// 发布说明（GitHub API 提供时才有）
  final String? notes;

  /// 命中的更新源：`清华镜像` / `GitHub`
  final String? source;

  /// 失败原因（status == failed 时有值）
  final String? error;

  const UpdateCheckResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.downloadUrl,
    this.downloadFileName,
    this.notes,
    this.source,
    this.error,
  });

  bool get hasUpdate => status == UpdateStatus.updateAvailable;
  bool get failed => status == UpdateStatus.failed;
}

/// 下载进度（UI 用来画百分比、速度与进度条）。
class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.receivedBytes,
    required this.bytesPerSecond,
    this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;

  /// 采样区间内的平均速度（字节/秒）
  final double bytesPerSecond;

  /// 总长未知时返回 null（进度条改为不确定态）
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  int? get percent {
    final f = fraction;
    return f == null ? null : (f * 100).round();
  }
}

/// 下载完成后的本地安装包。
class UpdateDownloadResult {
  const UpdateDownloadResult({
    required this.filePath,
    required this.downloadUrl,
    required this.sourceLabel,
    required this.bytes,
  });

  final String filePath;
  final String downloadUrl;
  final String sourceLabel;
  final int bytes;
}

/// 应用内更新失败（下载 / 启动安装器）。[downloadUrl] 留给 UI 做「复制链接」兜底。
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, {this.downloadUrl, this.attempts});

  final String message;
  final String? downloadUrl;
  final List<SmartAttempt>? attempts;

  @override
  String toString() => message;
}

/// 检查更新（v1.34）。
///
/// 顺序刻意是「清华镜像 → GitHub」：国内直连 `api.github.com` 常常超时，
/// 先用清华的 GitHub Release 镜像（只抓首页 tag 列表，一个 GET），
/// 镜像不可用再退到 GitHub API（能额外拿到发布说明与资产直链）。
///
/// 两条红线：
///   · 版本号唯一来源仍是 [kAppVersion]（pubspec 派生），这里只做比较，不引入
///     第二个版本常量——否则又会出现「APK 版本名与 App 内显示不一致」。
///   · 检查更新**只读**：不发遥测、不上报设备信息，请求就是公开页面的 GET。
class UpdateService {
  const UpdateService._();

  static const String repoOwner = 'Lamitis';
  static const String repoName = 'NatsumeQuizMaster';

  /// 清华 TUNA 的 GitHub Release 镜像首页（按 tag 分目录列出）
  static const String mirrorIndexUrl =
      'https://mirrors.tuna.tsinghua.edu.cn/github-release/$repoOwner/$repoName/';

  /// GitHub 最新发布 API
  static const String githubLatestApi =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';

  /// 兜底下载页（镜像与 API 都拿不到具体资产时用它）
  static const String releasesPage =
      'https://github.com/$repoOwner/$repoName/releases/latest';

  /// 单个请求超时：检查更新是「顺手点一下」的动作，不该让用户等太久
  static const Duration timeout = Duration(seconds: 8);

  /// 查最新版本。永不抛异常：失败也返回 [UpdateStatus.failed] 的结果，
  /// 由界面决定怎么提示（网络问题不该变成崩溃）。
  ///
  /// 顺序：清华镜像先用一个 GET 拿 tag（最省流量）；发现更新后再走
  /// SmartHttpClient 的 GitHub API 多源池拿资产直链与发布说明。镜像命中但
  /// API 失败时仍返回镜像结果（只能复制链接手动下载，不阻塞用户看到版本）。
  static Future<UpdateCheckResult> check({
    http.Client? client,
    String currentVersion = kAppVersion,
    String customMirror = '',
    SmartHttpClient? smartClient,
  }) async {
    final smart = _resolveSmart(
      client: client,
      customMirror: customMirror,
      smartClient: smartClient,
    );
    final effectiveMirror =
        customMirror.isNotEmpty ? customMirror : smart.customMirror;
    final failures = <String>[];

    // ① 清华镜像：只要 tag 列表，最省流量
    String? mirrorTag;
    try {
      final mirror = await smart.getFirst(
        const [SmartSource('清华镜像', mirrorIndexUrl)],
        timeout: timeout,
        headers: const {'User-Agent': 'NatsumeQuizMaster-update-check'},
        originalUrl: mirrorIndexUrl,
        failurePrefix: '清华镜像读取失败',
      );
      mirrorTag = latestTagFromMirrorIndex(mirror.text);
      if (mirrorTag == null) failures.add('清华镜像：页面里没有版本目录');
    } catch (e) {
      failures.add('清华镜像：$e');
    }

    // 镜像已经能证明「没有更新」就不必再打 GitHub API
    if (mirrorTag != null &&
        compareVersions(mirrorTag, currentVersion) <= 0) {
      return _build(
        current: currentVersion,
        latest: mirrorTag,
        downloadUrl: mirrorTagUrl(mirrorTag),
        notes: null,
        source: '清华镜像',
      );
    }

    // ② GitHub API：多源加速，顺带拿发布说明 + 资产直链
    try {
      final api = await smart.getFirst(
        SmartHttpClient.downloadCandidates(
          githubLatestApi,
          customMirror: effectiveMirror,
        ),
        timeout: timeout,
        headers: const {
          'Accept': 'application/vnd.github+json',
          // 未认证也要求 UA；不给会被 403
          'User-Agent': 'NatsumeQuizMaster-update-check',
        },
        originalUrl: githubLatestApi,
        failurePrefix: 'GitHub API 读取失败',
        validate: SmartHttpClient.looksLikeJson,
      );
      final data = jsonDecode(api.text);
      if (data is Map) {
        final tag = (data['tag_name'] ?? '').toString();
        if (tag.isNotEmpty) {
          final asset = pickDownloadAsset(
            assets: data['assets'],
            fallback: (data['html_url'] ?? releasesPage).toString(),
          );
          return _build(
            current: currentVersion,
            latest: tag,
            downloadUrl: asset.url,
            downloadFileName: asset.name,
            notes: _shortNotes(data['body']),
            source: api.label == '原始' ? 'GitHub' : 'GitHub·${api.label}',
          );
        }
        failures.add('GitHub：响应里没有 tag_name');
      } else {
        failures.add('GitHub：响应格式异常');
      }
    } catch (e) {
      failures.add('GitHub：$e');
    }

    // ③ API 挂了但镜像有 tag：至少让用户看到版本并复制链接手动下载
    if (mirrorTag != null) {
      return _build(
        current: currentVersion,
        latest: mirrorTag,
        downloadUrl: mirrorTagUrl(mirrorTag),
        notes: null,
        source: '清华镜像',
      );
    }

    return UpdateCheckResult(
      status: UpdateStatus.failed,
      currentVersion: currentVersion,
      error: '无法连接更新服务器（${failures.join('；')}）',
    );
  }


  static UpdateCheckResult _build({
    required String current,
    required String latest,
    required String downloadUrl,
    String? downloadFileName,
    required String? notes,
    required String source,
  }) {
    final cmp = compareVersions(latest, current);
    return UpdateCheckResult(
      // 远端比本地新才算「有更新」；相等或本地更新（开发中构建号更大）都不弹
      status: cmp > 0 ? UpdateStatus.updateAvailable : UpdateStatus.upToDate,
      currentVersion: current,
      latestVersion: latest,
      downloadUrl: downloadUrl,
      downloadFileName: downloadFileName,
      notes: notes,
      source: source,
    );
  }

  /// 镜像里某个 tag 的目录页（列出该版本的 apk/zip/exe）
  static String mirrorTagUrl(String tag) => '$mirrorIndexUrl$tag/';

  /// 从镜像首页 HTML 里挑出最新的 tag。
  ///
  /// 页面结构是 Apache 目录列表：每行 `<a href="v1.33.0/">v1.33.0/</a>`。
  /// 只认像版本号的目录名（`v1.33.0` / `1.33.0.26`），并按版本大小取最大——
  /// **不能按下标取第一个**：目录是字典序（`v1.9.0` 排在 `v1.10.0` 后面）。
  static String? latestTagFromMirrorIndex(String html) {
    final tags = <String>[];
    for (final m in RegExp(r'''href\s*=\s*["']([^"'?#]+)["']''',
            caseSensitive: false)
        .allMatches(html)) {
      var href = m.group(1)!.trim();
      if (href.startsWith('/') || href.startsWith('http')) continue;
      if (href.endsWith('/')) href = href.substring(0, href.length - 1);
      if (href.isEmpty || href.contains('/')) continue;
      if (!isVersionLike(href)) continue;
      if (!tags.contains(href)) tags.add(href);
    }
    if (tags.isEmpty) return null;
    tags.sort((a, b) => compareVersions(b, a));
    return tags.first;
  }

  /// 目录名像不像版本号（`v1.33.0`、`1.33.0.26`、`v1.34.0-rc1`）
  static bool isVersionLike(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 32) return false;
    return RegExp(r'^[vV]?\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]{1,16})?$')
        .hasMatch(t);
  }

  /// 版本比较：返回 >0 表示 [a] 比 [b] 新。
  ///
  /// 逐段比数字（`v1.33.0.26` 比 `v1.33.0` 多一段构建号），缺的段按 0 补。
  /// 前导 `v` 与预发布后缀（`-rc1`）不参与数字主序，但**带后缀的一律视为
  /// 比同号正式版旧**（`v1.34.0-rc1` < `v1.34.0`），避免把预发布当正式版推给用户。
  static int compareVersions(String a, String b) {
    final pa = versionParts(a);
    final pb = versionParts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    final preA = isPreRelease(a);
    final preB = isPreRelease(b);
    if (preA != preB) return preA ? -1 : 1;
    return 0;
  }

  /// 版本号切成数字段（`v1.33.0.26` → `[1, 33, 0, 26]`）
  @visibleForTesting
  static List<int> versionParts(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first;
    s = s.split('-').first;
    if (s.isEmpty) return const [0];
    return s
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList(growable: false);
  }

  /// 带 `-rc1` / `-beta` 这类后缀视为预发布
  @visibleForTesting
  static bool isPreRelease(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first;
    final dash = s.indexOf('-');
    if (dash < 0) return false;
    return s.substring(dash + 1).trim().isNotEmpty;
  }

  /// 从 GitHub 的 `assets` 里挑一个最合适的下载资产（URL + 文件名）。
  ///
  /// 优先当前平台的安装包（Android 找 `.apk`，Windows 找 `.exe` 再退 `.zip`），
  /// 找不到就用第一个资产，再不行用发布页。
  static ({String url, String? name}) pickDownloadAsset({
    required Object? assets,
    String fallback = releasesPage,
  }) {
    if (assets is! List || assets.isEmpty) return (url: fallback, name: null);
    final entries = <({String name, String url})>[];
    for (final a in assets) {
      if (a is! Map) continue;
      final url = (a['browser_download_url'] ?? '').toString();
      final name = (a['name'] ?? '').toString();
      if (url.isEmpty) continue;
      entries.add((name: name, url: url));
    }
    if (entries.isEmpty) return (url: fallback, name: null);
    final preferred = <String>[
      if (Platform.isAndroid) ...['.apk', '.zip'],
      if (Platform.isWindows) ...['.exe', '.zip'],
      '.apk',
      '.zip',
      '.exe',
    ];
    for (final ext in preferred) {
      for (final entry in entries) {
        if (entry.name.toLowerCase().endsWith(ext)) return entry;
      }
    }
    return entries.first;
  }

  /// 兼容旧调用：只要 URL。
  static String pickDownloadUrl({
    required Object? assets,
    String fallback = releasesPage,
  }) =>
      pickDownloadAsset(assets: assets, fallback: fallback).url;

  /// 应用内下载更新包：SmartHttpClient 多源回退 + 进度回调，文件落到缓存目录。
  ///
  /// - Windows 取 `.exe` / Android 取 `.apk`；镜像目录页这类非安装包链接会
  ///   直接抛出 [UpdateDownloadException]（UI 用「复制下载链接」兜底）；
  /// - [saveDir] 仅供测试注入；正常运行使用 `getTemporaryDirectory()`；
  /// - [onProgress] 的速度按两次回调之间的字节差估算，弱网下波动属正常。
  static Future<UpdateDownloadResult> downloadUpdate({
    required UpdateCheckResult update,
    http.Client? client,
    String customMirror = '',
    SmartHttpClient? smartClient,
    String? saveDir,
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    final downloadUrl = update.downloadUrl;
    if (downloadUrl == null || downloadUrl.trim().isEmpty) {
      throw const UpdateDownloadException('没有可用的下载地址');
    }
    final ext = _installerExtension(
      downloadUrl,
      update.downloadFileName,
    );
    if (ext == null) {
      throw UpdateDownloadException(
        '当前更新源只提供页面链接，无法应用内安装；请复制链接手动下载。',
        downloadUrl: downloadUrl,
      );
    }

    final dirPath = saveDir ?? (await getTemporaryDirectory()).path;
    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    final version = _safeFileName(update.latestVersion ?? kAppVersion);
    final savePath = p.join(dir.path, 'NatsumeQuizMaster-$version$ext');

    final smart = _resolveSmart(
      client: client,
      customMirror: customMirror,
      smartClient: smartClient,
    );
    final effectiveMirror =
        customMirror.isNotEmpty ? customMirror : smart.customMirror;
    final stopwatch = Stopwatch()..start();
    var lastBytes = 0;
    var lastElapsed = Duration.zero;

    try {
      final result = await smart.downloadToFile(
        url: downloadUrl,
        savePath: savePath,
        timeout: SmartHttpClient.defaultDownloadTimeout,
        customMirror: effectiveMirror,
        onProgress: (received, total) {
          final elapsed = stopwatch.elapsed;
          final deltaUs =
              (elapsed - lastElapsed).inMicroseconds.clamp(1, 1 << 31);
          final speed = (received - lastBytes) * 1000000 / deltaUs;
          lastBytes = received;
          lastElapsed = elapsed;
          onProgress?.call(UpdateDownloadProgress(
            receivedBytes: received,
            totalBytes: total,
            bytesPerSecond: speed < 0 ? 0 : speed,
          ));
        },
        failurePrefix: '更新包下载失败',
      );
      return UpdateDownloadResult(
        filePath: result.path,
        downloadUrl: downloadUrl,
        sourceLabel: result.label,
        bytes: result.bytes,
      );
    } on SmartHttpException catch (e) {
      throw UpdateDownloadException(
        e.message,
        downloadUrl: downloadUrl,
        attempts: e.attempts,
      );
    }
  }

  /// 拉起刚下载好的安装包：Windows 直接打开 `.exe`；Android 走 `open_filex`。
  ///
  /// 返回 false 表示启动失败（或平台不支持），UI 应提示「复制下载链接」。
  static Future<bool> installUpdate(
    UpdateDownloadResult download, {
    Future<bool> Function(String path)? openInstaller,
  }) async {
    if (!await File(download.filePath).exists()) return false;
    if (openInstaller != null) return openInstaller(download.filePath);
    try {
      if (Platform.isWindows) {
        // 优先系统 shell 打开 .exe；个别环境 file URI 不可用则直接 detached 启动
        try {
          if (await launchUrl(
            Uri.file(download.filePath),
            mode: LaunchMode.externalApplication,
          )) {
            return true;
          }
        } catch (_) {
          // 落到下面的 Process.start
        }
        await Process.start(
          download.filePath,
          const [],
          mode: ProcessStartMode.detached,
        );
        return true;
      }
      if (Platform.isAndroid) {
        final result = await OpenFilex.open(download.filePath);
        return result.type == ResultType.done;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// 这个更新结果能否应用内下载安装（平台匹配：Windows 只认 `.exe`，Android 只认 `.apk`）。
  static bool canInstallInApp(UpdateCheckResult update) {
    final ext = _installerExtension(
      update.downloadUrl ?? '',
      update.downloadFileName,
    );
    if (Platform.isWindows) return ext == '.exe';
    if (Platform.isAndroid) return ext == '.apk';
    return false;
  }

  /// 根据 URL / 资产名判断安装包类型；不是 `.exe` / `.apk` 返回 null。
  @visibleForTesting
  static String? installerExtension(String url, [String? fileName]) =>
      _installerExtension(url, fileName);

  static String? _installerExtension(String url, String? fileName) {
    final candidates = <String>[
      if (fileName != null && fileName.isNotEmpty) fileName,
      Uri.tryParse(url)?.path ?? '',
    ];
    for (final name in candidates) {
      final lower = name.toLowerCase();
      if (lower.endsWith('.apk')) return '.apk';
      if (lower.endsWith('.exe')) return '.exe';
    }
    return null;
  }

  static String _safeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    return sanitized.isEmpty ? 'update' : sanitized;
  }

  /// 未显式注入 client 时复用全局单例：自定义镜像由 AppState 同步进去，
  /// 更新下载也应享受同一套加速设置。
  static SmartHttpClient _resolveSmart({
    http.Client? client,
    String customMirror = '',
    SmartHttpClient? smartClient,
  }) {
    if (smartClient != null) return smartClient;
    if (client == null && customMirror.isEmpty) {
      return SmartHttpClient.instance;
    }
    return SmartHttpClient(client: client, customMirror: customMirror);
  }

  /// 发布说明截断（弹窗里只留前 600 字，避免整篇 CHANGELOG 撑爆对话框）
  static String? _shortNotes(Object? body) {
    final s = (body ?? '').toString().trim();
    if (s.isEmpty) return null;
    return s.length <= 600 ? s : '${s.substring(0, 600)}…';
  }

  /// 打开下载页（外部浏览器），成功返回 true。
  static Future<bool> openDownload(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
