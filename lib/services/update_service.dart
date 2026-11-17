import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// 目标平台。
///
/// 从 [Platform] 拆出来是为了让「挑哪个资产」可测：单测跑在 Windows 上，
/// 但仍需要断言 Android 端绝不选 `.zip` / `SHA256SUMS.txt`。
enum UpdatePlatform { android, windows, other }

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

  /// `SHA256SUMS.txt` 的直链与文件名（发布里提供时才有）。
  ///
  /// v1.42.1：下载完成后用它校验安装包，拦截运营商劫持的 HTML 广告页 /
  /// 半截文件；拿不到校验文件时仍允许安装，但结果里会标记「未校验」。
  final String? checksumUrl;
  final String? checksumFileName;

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
    this.checksumUrl,
    this.checksumFileName,
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
    this.checksumVerified = false,
  });

  final String filePath;
  final String downloadUrl;
  final String sourceLabel;
  final int bytes;

  /// 是否用发布里的 `SHA256SUMS.txt` 校验通过。
  ///
  /// false 有两种情况：发布没提供校验文件，或校验文件请求失败（弱网）。
  /// UI 会把「未校验」显示出来，让用户知道这次安装少了一道防线。
  final bool checksumVerified;
}

/// 拉起安装器的结果：比 bool 多一句可执行的提示。
class UpdateInstallOutcome {
  const UpdateInstallOutcome({required this.ok, this.reason});

  final bool ok;

  /// 失败原因 + 用户下一步该做什么（直接展示在更新弹窗里）。
  final String? reason;

  static const UpdateInstallOutcome success = UpdateInstallOutcome(ok: true);
}

/// 应用内更新失败（下载 / 启动安装器）。[downloadUrl] 留给 UI 做「复制链接」兜底。
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message,
      {this.downloadUrl, this.attempts});

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
    UpdatePlatform? platform,
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
    if (mirrorTag != null && compareVersions(mirrorTag, currentVersion) <= 0) {
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
            platform: platform,
          );
          final checksum = pickChecksumAsset(assets: data['assets']);
          return _build(
            current: currentVersion,
            latest: tag,
            downloadUrl: asset.url,
            downloadFileName: asset.name,
            checksumUrl: checksum.url.isEmpty ? null : checksum.url,
            checksumFileName: checksum.name,
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
    String? checksumUrl,
    String? checksumFileName,
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
      checksumUrl: checksumUrl,
      checksumFileName: checksumFileName,
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
    for (final m
        in RegExp(r'''href\s*=\s*["']([^"'?#]+)["']''', caseSensitive: false)
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

  /// 当前运行平台（测试可显式传 [UpdatePlatform] 覆盖）。
  static UpdatePlatform get currentPlatform {
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isWindows) return UpdatePlatform.windows;
    return UpdatePlatform.other;
  }

  /// 取文件名末段：兼容完整 URL、带 query 的下载链接与 Windows 反斜杠。
  static String _baseName(String value) {
    var s = value.trim();
    if (s.isEmpty) return '';
    final uri = Uri.tryParse(s);
    if (uri != null && uri.hasScheme && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    s = s.split(RegExp(r'[?#]')).first;
    final slash = s.lastIndexOf(RegExp(r'[\\/]'));
    return slash >= 0 ? s.substring(slash + 1) : s;
  }

  /// 资产名像不像「校验 / 说明」文件（绝不作为安装包）。
  static bool _isNonInstallerName(String name) {
    final n = name.toLowerCase().trim();
    if (n.isEmpty) return true;
    return n.contains('sha256') ||
        n.contains('sha512') ||
        n.contains('md5') ||
        n.contains('checksum') ||
        n.contains('digest') ||
        n.endsWith('.txt') ||
        n.endsWith('.json') ||
        n.endsWith('.blockmap') ||
        n.endsWith('.sig') ||
        n.endsWith('.asc') ||
        n.endsWith('.zip') ||
        n.endsWith('.7z');
  }

  /// 是否是指定平台的安装包：Android 只认 `.apk`，Windows 只认 `.exe`。
  ///
  /// `.zip`、`SHA256SUMS.txt`、说明文件一律不算——它们交给浏览器手动下载，
  /// 绝不进入应用内安装流程（否则系统会报「解析失败」）。
  @visibleForTesting
  static bool isInstallerForPlatform(
      String nameOrUrl, UpdatePlatform platform) {
    final n = _baseName(nameOrUrl).toLowerCase();
    if (n.isEmpty || _isNonInstallerName(n)) return false;
    return switch (platform) {
      UpdatePlatform.android => n.endsWith('.apk'),
      UpdatePlatform.windows => n.endsWith('.exe'),
      UpdatePlatform.other => false,
    };
  }

  /// 从 GitHub 的 `assets` 里挑一个最合适的安装包（URL + 文件名）。
  ///
  /// v1.42.1 收紧：只挑**当前平台**的安装包（Android `.apk` / Windows `.exe`），
  /// 不再退到 `.zip`，也不会把 `SHA256SUMS.txt`、`.blockmap` 当安装包。
  /// 没有匹配资产时返回 [fallback]（通常是发布页），由 UI 走「浏览器下载」。
  static ({String url, String? name}) pickDownloadAsset({
    required Object? assets,
    String fallback = releasesPage,
    UpdatePlatform? platform,
  }) {
    final target = platform ?? currentPlatform;
    if (target == UpdatePlatform.other) return (url: fallback, name: null);
    if (assets is! List || assets.isEmpty) return (url: fallback, name: null);
    for (final a in assets) {
      if (a is! Map) continue;
      final url = (a['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      final rawName = (a['name'] ?? '').toString();
      final label = _baseName(rawName.isEmpty ? url : rawName);
      if (!isInstallerForPlatform(label, target)) continue;
      return (url: url, name: rawName.isEmpty ? label : rawName);
    }
    return (url: fallback, name: null);
  }

  /// 从 `assets` 里挑 `SHA256SUMS.txt`（或 `.sha256` / `.sha256sum`）。
  static ({String url, String? name}) pickChecksumAsset({
    required Object? assets,
  }) {
    if (assets is! List || assets.isEmpty) return (url: '', name: null);
    final entries = <({String name, String url})>[];
    for (final a in assets) {
      if (a is! Map) continue;
      final url = (a['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      final rawName = (a['name'] ?? '').toString();
      entries.add((name: _baseName(rawName.isEmpty ? url : rawName), url: url));
    }
    for (final e in entries) {
      if (e.name.toLowerCase() == 'sha256sums.txt') {
        return (url: e.url, name: e.name);
      }
    }
    for (final e in entries) {
      final n = e.name.toLowerCase();
      if (n.contains('sha256sum') ||
          n.endsWith('.sha256') ||
          n.endsWith('.sha256sum')) {
        return (url: e.url, name: e.name);
      }
    }
    return (url: '', name: null);
  }

  /// 兼容旧调用：只要 URL。
  static String pickDownloadUrl({
    required Object? assets,
    String fallback = releasesPage,
    UpdatePlatform? platform,
  }) =>
      pickDownloadAsset(assets: assets, fallback: fallback, platform: platform)
          .url;

  /// 应用内下载更新包：SmartHttpClient 多源回退 + 进度回调，文件落到缓存目录。
  ///
  /// v1.42.1 修复「下载完无法安装 / 解析失败」的四条防线：
  /// 1. 扩展名只认当前平台（Android `.apk` / Windows `.exe`），其余直接拒绝；
  /// 2. 先写 `<文件名>.part`，校验通过后才重命名为正式后缀——系统扫描 / 安装器
  ///    永远看不到半截文件或 `.tmp`；
  /// 3. 校验文件头（APK 是 ZIP `PK`，EXE 是 `MZ`），被运营商替换成 HTML 广告页
  ///    时直接报错并删除；
  /// 4. 发布带 `SHA256SUMS.txt` 时比对 SHA-256，不一致同样删除并报错。
  ///
  /// - [platform] 仅供测试注入；默认 [currentPlatform]；
  /// - [saveDir] 仅供测试注入；正常运行使用 `getTemporaryDirectory()`。
  static Future<UpdateDownloadResult> downloadUpdate({
    required UpdateCheckResult update,
    http.Client? client,
    String customMirror = '',
    SmartHttpClient? smartClient,
    String? saveDir,
    UpdatePlatform? platform,
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    final target = platform ?? currentPlatform;
    final downloadUrl = update.downloadUrl;
    if (downloadUrl == null || downloadUrl.trim().isEmpty) {
      throw const UpdateDownloadException('没有可用的下载地址');
    }
    final expectedExt = switch (target) {
      UpdatePlatform.android => '.apk',
      UpdatePlatform.windows => '.exe',
      UpdatePlatform.other => null,
    };
    final ext = _installerExtension(downloadUrl, update.downloadFileName);
    if (ext == null || expectedExt == null || ext != expectedExt) {
      throw UpdateDownloadException(
        '当前平台只支持应用内安装 ${expectedExt ?? '受支持的'} 安装包'
        '（更新源提供的是 ${ext ?? '页面链接'}，可能是其他平台的资产）；'
        '请复制链接手动下载。',
        downloadUrl: downloadUrl,
      );
    }

    final dirPath = saveDir ?? (await getTemporaryDirectory()).path;
    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    final version = _safeFileName(update.latestVersion ?? kAppVersion);
    final finalPath = p.join(dir.path, 'NatsumeQuizMaster-$version$ext');
    // 先落 .part：下载 / 校验期间不会被系统安装器或文件管理器当成安装包
    final partFile = File('$finalPath.part');
    if (await partFile.exists()) {
      try {
        await partFile.delete();
      } catch (_) {}
    }

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
    int? expectedTotal;

    try {
      final result = await smart.downloadToFile(
        url: downloadUrl,
        savePath: partFile.path,
        timeout: SmartHttpClient.defaultDownloadTimeout,
        customMirror: effectiveMirror,
        onProgress: (received, total) {
          if (total != null && total > 0) expectedTotal = total;
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

      final bytes = result.bytes;
      if (bytes <= 0) {
        throw UpdateDownloadException(
          '下载到的安装包为空，请重试或复制链接手动下载。',
          downloadUrl: downloadUrl,
        );
      }
      if (expectedTotal != null &&
          expectedTotal! > 0 &&
          bytes != expectedTotal) {
        throw UpdateDownloadException(
          '安装包下载不完整（$bytes / ${expectedTotal!} 字节），请重试。',
          downloadUrl: downloadUrl,
        );
      }
      // 文件头校验：APK 一定是 ZIP（PK），Windows 安装器一定是 MZ
      if (!await _looksLikeInstaller(partFile, ext)) {
        throw UpdateDownloadException(
          '下载到的文件不是有效的 $ext 安装包（可能是网络劫持页面或错误资产），'
          '已删除并停止安装；请重试或复制链接手动下载。',
          downloadUrl: downloadUrl,
        );
      }

      // 发布提供 SHA256SUMS.txt 时比对哈希；拿不到校验文件不阻断，但标记未校验
      final verified = await _verifyChecksum(
        smart: smart,
        update: update,
        file: partFile,
        mirror: effectiveMirror,
      );

      final out = File(finalPath);
      if (await out.exists()) {
        try {
          await out.delete();
        } catch (_) {}
      }
      await partFile.rename(finalPath);
      return UpdateDownloadResult(
        filePath: finalPath,
        downloadUrl: downloadUrl,
        sourceLabel: result.label,
        bytes: bytes,
        checksumVerified: verified,
      );
    } on SmartHttpException catch (e) {
      throw UpdateDownloadException(
        e.message,
        downloadUrl: downloadUrl,
        attempts: e.attempts,
      );
    } finally {
      // 任何异常 / 校验失败都不能把半截 .part 留在缓存里
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
    }
  }

  /// 用发布里的 `SHA256SUMS.txt` 校验文件；返回是否校验通过。
  ///
  /// - 发布没有校验文件 → 返回 false（UI 显示「未校验」）；
  /// - 校验文件请求失败 → 返回 false（弱网不阻断安装）；
  /// - 校验文件有该资产但哈希不符 → 抛 [UpdateDownloadException]；
  /// - 校验文件里找不到该资产 → 抛异常（不能假装校验过）。
  static Future<bool> _verifyChecksum({
    required SmartHttpClient smart,
    required UpdateCheckResult update,
    required File file,
    required String mirror,
  }) async {
    final checksumUrl = update.checksumUrl;
    if (checksumUrl == null || checksumUrl.trim().isEmpty) return false;
    final SmartHttpResult sums;
    try {
      sums = await smart.getFirst(
        SmartHttpClient.downloadCandidates(checksumUrl, customMirror: mirror),
        timeout: timeout,
        headers: const {'User-Agent': 'NatsumeQuizMaster-update-check'},
        originalUrl: checksumUrl,
        failurePrefix: 'SHA256SUMS.txt 下载失败',
      );
    } catch (_) {
      return false;
    }
    final assetName = (update.downloadFileName != null &&
            update.downloadFileName!.trim().isNotEmpty)
        ? update.downloadFileName!
        : (update.downloadUrl ?? '');
    final expected = parseChecksum(sums.text, assetName);
    if (expected == null) {
      throw UpdateDownloadException(
        '校验文件里没有找到当前安装包的 SHA-256，已停止安装；请重试或手动下载。',
        downloadUrl: update.downloadUrl,
      );
    }
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual.toLowerCase() != expected.toLowerCase()) {
      throw UpdateDownloadException(
        '安装包 SHA-256 校验失败（文件可能被篡改或下载不完整），已删除；'
        '请重试或复制链接手动下载。',
        downloadUrl: update.downloadUrl,
      );
    }
    return true;
  }

  /// 看文件头判断是不是真正的安装包（HTML 广告页 / JSON 错误页会被识破）。
  @visibleForTesting
  static Future<bool> looksLikeInstaller(String path, String ext) =>
      _looksLikeInstaller(File(path), ext);

  static Future<bool> _looksLikeInstaller(File file, String ext) async {
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      if (head.length < 2) return false;
      if (ext == '.apk') return head[0] == 0x50 && head[1] == 0x4B;
      if (ext == '.exe') return head[0] == 0x4D && head[1] == 0x5A;
      return false;
    } finally {
      await raf.close();
    }
  }

  /// 从 `SHA256SUMS.txt` 里取指定文件的哈希。
  ///
  /// 兼容 `hash  name` / `hash *name` / 路径前缀（`dist/app.apk`）。
  @visibleForTesting
  static String? parseChecksum(String text, String fileName) {
    final target = _baseName(fileName).toLowerCase();
    if (target.isEmpty) return null;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line);
      if (m == null) continue;
      if (_baseName(m.group(2)!.trim()).toLowerCase() != target) continue;
      return m.group(1)!.toLowerCase();
    }
    return null;
  }

  /// 拉起刚下载好的安装包：Windows 直接打开 `.exe`；Android 走 `open_filex`。
  ///
  /// 返回 false 表示启动失败（或平台不支持）；需要失败原因时用
  /// [installUpdateDetailed]（UI 用它展示「允许安装未知应用 / 先卸载旧版」）。
  static Future<bool> installUpdate(
    UpdateDownloadResult download, {
    Future<bool> Function(String path)? openInstaller,
  }) async =>
      (await installUpdateDetailed(download, openInstaller: openInstaller)).ok;

  /// 拉起安装器并给出可执行的失败提示。
  ///
  /// v1.42.1：
  /// - Windows 先 `Process.start`（detached）再退 `file://` 的 `launchUrl`，
  ///   不再只依赖 URL 打开本地 exe；
  /// - Android 把 `open_filex` 的 `ResultType` 翻译成人话（权限 / 无安装器 /
  ///   签名冲突），不再笼统地「启动失败」。
  static Future<UpdateInstallOutcome> installUpdateDetailed(
    UpdateDownloadResult download, {
    Future<bool> Function(String path)? openInstaller,
  }) async {
    final file = File(download.filePath);
    if (!await file.exists()) {
      return const UpdateInstallOutcome(
        ok: false,
        reason: '安装包不存在或已被系统清理，请重新下载。',
      );
    }
    if (openInstaller != null) {
      final ok = await openInstaller(download.filePath);
      return ok
          ? UpdateInstallOutcome.success
          : const UpdateInstallOutcome(
              ok: false,
              reason: '安装程序启动失败，可点「打开安装包」重试，或复制下载链接手动安装。',
            );
    }

    final ext = _installerExtension(
      download.downloadUrl,
      p.basename(download.filePath),
    );
    if (Platform.isWindows) {
      if (ext != '.exe') {
        return const UpdateInstallOutcome(
          ok: false,
          reason: '当前平台只支持 .exe 安装包，请到发布页下载 Windows 版本。',
        );
      }
      // ① 直接 detached 启动：最可靠，且不受 file:// 关联影响
      try {
        await Process.start(
          download.filePath,
          const [],
          mode: ProcessStartMode.detached,
          runInShell: true,
        );
        return UpdateInstallOutcome.success;
      } catch (_) {}
      // ② 退到系统 shell（file://）
      try {
        if (await launchUrl(
          Uri.file(download.filePath),
          mode: LaunchMode.externalApplication,
        )) {
          return UpdateInstallOutcome.success;
        }
      } catch (_) {}
      return const UpdateInstallOutcome(
        ok: false,
        reason: '无法启动安装程序：请右键安装包 →「以管理员身份运行」；'
            '若被 SmartScreen 拦截，点「更多信息」→「仍要运行」。',
      );
    }

    if (Platform.isAndroid) {
      if (ext != '.apk') {
        return const UpdateInstallOutcome(
          ok: false,
          reason: '当前平台只支持 .apk 安装包，请到发布页下载 Android 版本。',
        );
      }
      try {
        final result = await OpenFilex.open(download.filePath);
        switch (result.type) {
          case ResultType.done:
            return UpdateInstallOutcome.success;
          case ResultType.permissionDenied:
            return const UpdateInstallOutcome(
              ok: false,
              reason: '系统拒绝了安装请求：请到「设置 → 应用 → 特殊权限 → 安装未知应用」'
                  '允许本应用后，点「打开安装包」重试。',
            );
          case ResultType.noAppToOpen:
            return const UpdateInstallOutcome(
              ok: false,
              reason: '系统没有可用的安装器：请到文件管理器手动打开安装包。',
            );
          case ResultType.fileNotFound:
            return const UpdateInstallOutcome(
              ok: false,
              reason: '安装包不存在或已被系统清理，请重新下载。',
            );
          case ResultType.error:
            return UpdateInstallOutcome(
              ok: false,
              reason: '安装失败：${result.message}。'
                  '若提示「签名不一致 / 应用未安装」，请先卸载旧版本再安装。',
            );
        }
      } catch (e) {
        return UpdateInstallOutcome(
          ok: false,
          reason: '安装失败：$e。若提示签名不一致，请先卸载旧版本再安装。',
        );
      }
    }

    return const UpdateInstallOutcome(
      ok: false,
      reason: '当前平台不支持应用内安装。',
    );
  }

  /// 这个更新结果能否应用内下载安装（平台匹配：Windows 只认 `.exe`，Android 只认 `.apk`）。
  static bool canInstallInApp(
    UpdateCheckResult update, {
    UpdatePlatform? platform,
  }) {
    final target = platform ?? currentPlatform;
    final ext = _installerExtension(
      update.downloadUrl ?? '',
      update.downloadFileName,
    );
    final expected = switch (target) {
      UpdatePlatform.android => '.apk',
      UpdatePlatform.windows => '.exe',
      UpdatePlatform.other => null,
    };
    return expected != null && ext == expected;
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
