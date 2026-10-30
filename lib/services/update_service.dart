import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_constants.dart';

/// 检查更新的结果状态。
enum UpdateStatus { updateAvailable, upToDate, failed }

/// 检查更新结果（纯数据，方便测试直接断言）。
class UpdateCheckResult {
  final UpdateStatus status;

  /// 当前 App 版本（[kAppVersion]，形如 `v1.33.0.26`）
  final String currentVersion;

  /// 远端最新 tag（拿不到时为 null）
  final String? latestVersion;

  /// 下载页 / 资产直链（拿不到时为 null）
  final String? downloadUrl;

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
    this.notes,
    this.source,
    this.error,
  });

  bool get hasUpdate => status == UpdateStatus.updateAvailable;
  bool get failed => status == UpdateStatus.failed;
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
  static Future<UpdateCheckResult> check({
    http.Client? client,
    String currentVersion = kAppVersion,
  }) async {
    final httpClient = client ?? http.Client();
    final ownClient = client == null;
    final failures = <String>[];
    try {
      // ① 清华镜像：只要 tag 列表，最省流量
      try {
        final resp =
            await httpClient.get(Uri.parse(mirrorIndexUrl)).timeout(timeout);
        if (resp.statusCode == 200) {
          final tag = latestTagFromMirrorIndex(
              utf8.decode(resp.bodyBytes, allowMalformed: true));
          if (tag != null) {
            return _build(
              current: currentVersion,
              latest: tag,
              downloadUrl: mirrorTagUrl(tag),
              notes: null,
              source: '清华镜像',
            );
          }
          failures.add('清华镜像：页面里没有版本目录');
        } else {
          failures.add('清华镜像：HTTP ${resp.statusCode}');
        }
      } catch (e) {
        failures.add('清华镜像：$e');
      }

      // ② GitHub API：顺带拿发布说明 + 资产直链
      try {
        final resp = await httpClient
            .get(
              Uri.parse(githubLatestApi),
              headers: const {
                'Accept': 'application/vnd.github+json',
                // 未认证也要求 UA；不给会被 403
                'User-Agent': 'NatsumeQuizMaster-update-check',
              },
            )
            .timeout(timeout);
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes));
          if (data is Map) {
            final tag = (data['tag_name'] ?? '').toString();
            if (tag.isNotEmpty) {
              return _build(
                current: currentVersion,
                latest: tag,
                downloadUrl: pickDownloadUrl(
                  assets: data['assets'],
                  fallback: (data['html_url'] ?? releasesPage).toString(),
                ),
                notes: _shortNotes(data['body']),
                source: 'GitHub',
              );
            }
            failures.add('GitHub：响应里没有 tag_name');
          } else {
            failures.add('GitHub：响应格式异常');
          }
        } else {
          failures.add('GitHub：HTTP ${resp.statusCode}');
        }
      } catch (e) {
        failures.add('GitHub：$e');
      }

      return UpdateCheckResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        error: '无法连接更新服务器（${failures.join('；')}）',
      );
    } finally {
      if (ownClient) httpClient.close();
    }
  }


  static UpdateCheckResult _build({
    required String current,
    required String latest,
    required String downloadUrl,
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

  /// 从 GitHub 的 `assets` 里挑一个最合适的下载链接。
  ///
  /// 优先当前平台的安装包（Android 找 `.apk`，Windows 找 `.exe` 再退 `.zip`），
  /// 找不到就用第一个资产，再不行用发布页。
  static String pickDownloadUrl({
    required Object? assets,
    String fallback = releasesPage,
  }) {
    if (assets is! List || assets.isEmpty) return fallback;
    final urls = <String, String>{}; // 文件名(小写) → 直链
    for (final a in assets) {
      if (a is! Map) continue;
      final url = (a['browser_download_url'] ?? '').toString();
      final name = (a['name'] ?? '').toString().toLowerCase();
      if (url.isEmpty) continue;
      urls[name] = url;
    }
    if (urls.isEmpty) return fallback;
    final preferred = <String>[
      if (Platform.isAndroid) ...['.apk', '.zip'],
      if (Platform.isWindows) ...['.exe', '.zip'],
      '.apk',
      '.zip',
      '.exe',
    ];
    for (final ext in preferred) {
      for (final entry in urls.entries) {
        if (entry.key.endsWith(ext)) return entry.value;
      }
    }
    return urls.values.first;
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
