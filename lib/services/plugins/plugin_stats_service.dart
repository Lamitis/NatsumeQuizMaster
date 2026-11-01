import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_registry.dart';

/// 批量拉「下载量 / 版本历史」（市场页与详情页共用；测试注入用）
typedef PluginStatsBatchLoader = Future<PluginStatsSnapshot> Function(
    List<RegistryPlugin> entries, {bool forceRefresh});

/// 拉单个仓库的元信息（详情页信息表用；测试注入用）
typedef RepoMetaLoader = Future<PluginRepoMeta?> Function(GitHubRepoRef ref,
    {bool forceRefresh});

/// GitHub 仓库坐标。
///
/// 登记表不托管文件、也没有自己的统计服务，下载量与版本历史只能向 GitHub 要。
/// 只认把 `owner/repo` 放在路径前两段的域名（[hosts]）；`objects.githubusercontent.com`
/// 这类签名 CDN 地址里没有 owner，解析不出来就当「没有统计」，不猜。
@immutable
class GitHubRepoRef {
  const GitHubRepoRef({required this.owner, required this.repo});

  final String owner;
  final String repo;

  /// `owner/repo`（缓存 key 也用它）
  String get slug => '$owner/$repo';

  Uri get releasesApi =>
      Uri.parse('https://api.github.com/repos/$slug/releases?per_page=20');

  Uri get repoApi => Uri.parse('https://api.github.com/repos/$slug');

  String get webUrl => 'https://github.com/$slug';

  String releaseUrl(String tag) => '$webUrl/releases/tag/$tag';

  static const Set<String> hosts = {
    'github.com',
    'raw.githubusercontent.com',
    'codeload.github.com',
  };

  /// owner / repo 的合法字符（GitHub 的实际约束，放宽到 100 字符够用）
  static final RegExp _segment = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$');

  /// 从下载地址（或仓库地址）里抠出 `owner/repo`；认不出返回 null。
  static GitHubRepoRef? parse(String? url) {
    if (url == null) return null;
    final raw = url.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    if (!hosts.contains(uri.host.toLowerCase())) return null;
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    final owner = segments[0];
    final repo = segments[1];
    if (!_segment.hasMatch(owner) || !_segment.hasMatch(repo)) return null;
    if (owner == '.' || owner == '..' || repo == '.' || repo == '..') return null;
    return GitHubRepoRef(owner: owner, repo: repo);
  }

  @override
  bool operator ==(Object other) =>
      other is GitHubRepoRef && other.owner == owner && other.repo == repo;

  @override
  int get hashCode => Object.hash(owner, repo);

  @override
  String toString() => slug;
}

/// 发布包里的一个文件（只留展示要用的字段）
@immutable
class PluginAsset {
  const PluginAsset({
    required this.name,
    this.downloadCount = 0,
    this.sizeBytes = 0,
  });

  final String name;

  /// GitHub 统计的下载次数
  final int downloadCount;

  /// 文件大小（字节）
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
        'name': name,
        'download_count': downloadCount,
        'size': sizeBytes,
      };

  static PluginAsset fromJson(Map<String, dynamic> json) => PluginAsset(
        name: (json['name'] ?? '').toString(),
        downloadCount: _asInt(json['download_count']),
        sizeBytes: _asInt(json['size']),
      );
}

/// 一次发布（对应 GitHub releases 的一项）
@immutable
class PluginRelease {
  const PluginRelease({
    required this.tag,
    this.name,
    this.publishedAt,
    this.prerelease = false,
    this.downloadCount = 0,
    this.assets = const [],
  });

  final String tag;
  final String? name;
  final DateTime? publishedAt;

  /// 预发布版本：进「版本历史」，但不参与「最新更新」的时间判断
  final bool prerelease;

  /// 该 release 全部 asset 的下载次数之和
  final int downloadCount;

  final List<PluginAsset> assets;

  Map<String, dynamic> toJson() => {
        'tag': tag,
        if (name != null) 'name': name,
        if (publishedAt != null) 'published_at': publishedAt!.toIso8601String(),
        'prerelease': prerelease,
        'download_count': downloadCount,
        'assets': [for (final a in assets) a.toJson()],
      };

  static PluginRelease? fromJson(Map<String, dynamic> json) {
    final tag = (json['tag'] ?? '').toString();
    if (tag.isEmpty) return null;
    final rawAssets = json['assets'];
    return PluginRelease(
      tag: tag,
      name: json['name']?.toString(),
      publishedAt: _asDate(json['published_at']),
      prerelease: json['prerelease'] == true,
      downloadCount: _asInt(json['download_count']),
      assets: rawAssets is List
          ? [
              for (final a in rawAssets)
                if (a is Map) PluginAsset.fromJson(a.cast<String, dynamic>()),
            ]
          : const [],
    );
  }
}

/// 一个插件的 GitHub 统计。
///
/// 「下载量」的口径写在 [PluginStats.fromReleases] 里：优先只数**同名发布包**，
/// 同名找不到才退回「全部 asset 之和」（数字偏大），所以 UI 上写成「约 N 次」。
@immutable
class PluginStats {
  const PluginStats({
    required this.downloadCount,
    this.latestReleaseAt,
    this.assetSizeBytes,
    this.releases = const [],
    this.fetchedAt,
    this.exact = false,
  });

  final int downloadCount;

  /// 最新一次**正式**发布的时间（没有正式发布就取最近的，含预发布）
  final DateTime? latestReleaseAt;

  /// 发布包大小（字节）；没匹配到同名 asset 时取最大的那个
  final int? assetSizeBytes;

  /// 版本历史（新的在前）
  final List<PluginRelease> releases;

  /// 这份数据是什么时候从 GitHub 拿的（缓存判鲜用）
  final DateTime? fetchedAt;

  /// 下载量是否只数了同名发布包（true）；false = 退回了「全部 asset 之和」，
  /// 数字偏大，UI 文案前面要加「约」
  final bool exact;

  bool isFresh(DateTime now, Duration ttl) {
    final at = fetchedAt;
    if (at == null) return false;
    return now.difference(at) < ttl;
  }

  PluginStats copyWith({DateTime? fetchedAt}) => PluginStats(
        downloadCount: downloadCount,
        latestReleaseAt: latestReleaseAt,
        assetSizeBytes: assetSizeBytes,
        releases: releases,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        exact: exact,
      );

  /// 卡片/信息表用的一句话：`1,234 次下载` 或 `约 1.2 万 次下载`
  String get downloadText =>
      exact ? '$downloadLabel 次下载' : '约 $downloadLabel 次下载';

  /// `1,234` / `1.2 万` —— 卡片与信息表共用
  String get downloadLabel => formatCount(downloadCount);

  /// 计数文案：不足 1000 原样，四位数加千分位，上万折算成「万」
  static String formatCount(int n) {
    if (n < 0) return '—';
    if (n < 1000) return '$n';
    if (n < 10000) return _thousands(n);
    final wan = n / 10000;
    final text = wan >= 100 ? wan.toStringAsFixed(0) : wan.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} 万';
  }

  /// `812 KB` / `1.4 MB`；没有数字就 `—`（信息表里宁可空着也不编）
  static String formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  /// `2026-10-31`（本地时区）；没有就 `—`
  static String formatDate(DateTime? at) {
    if (at == null) return '—';
    final d = at.toLocal();
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  /// 解析 `/releases` 的 JSON；看不懂 / 一条发布都没有时返回 null
  /// （页面显示「没有数字」，而不是编一个 0 出来）。
  static PluginStats? fromReleasesJson(String body, {String? assetName}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return null;
      final releases = <PluginRelease>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final json = item.cast<String, dynamic>();
        if (json['draft'] == true) continue;
        final tag = (json['tag_name'] ?? '').toString();
        if (tag.isEmpty) continue;
        final assets = <PluginAsset>[];
        final rawAssets = json['assets'];
        if (rawAssets is List) {
          for (final a in rawAssets) {
            if (a is! Map) continue;
            assets.add(PluginAsset.fromJson(a.cast<String, dynamic>()));
          }
        }
        releases.add(PluginRelease(
          tag: tag,
          name: (json['name'] ?? '').toString().isEmpty
              ? null
              : json['name'].toString(),
          publishedAt: _asDate(json['published_at'] ?? json['created_at']),
          prerelease: json['prerelease'] == true,
          downloadCount: assets.fold(0, (sum, a) => sum + a.downloadCount),
          assets: assets,
        ));
      }
      if (releases.isEmpty) return null;
      return PluginStats.fromReleases(releases, assetName: assetName);
    } catch (_) {
      return null;
    }
  }

  /// 汇总口径：
  /// - 有同名 asset（[assetName] 命中）→ **只数这些**：一个仓库挂多个插件时，
  ///   不会被别家的下载量污染；
  /// - 一个都没命中（包改过名）→ 退回全部 asset 之和，宁大不小，UI 用「约」兜住。
  factory PluginStats.fromReleases(
    List<PluginRelease> releases, {
    String? assetName,
  }) {
    final wanted = (assetName ?? '').trim();
    var matchedCount = 0;
    var matchedHits = 0;
    int? matchedSize;
    for (final r in releases) {
      for (final a in r.assets) {
        if (wanted.isEmpty || a.name != wanted) continue;
        matchedHits++;
        matchedCount += a.downloadCount;
        if (matchedSize == null || a.sizeBytes > matchedSize) {
          matchedSize = a.sizeBytes;
        }
      }
    }

    var count = matchedCount;
    int? size = matchedSize;
    if (matchedHits == 0) {
      count = 0;
      size = null;
      for (final r in releases) {
        for (final a in r.assets) {
          count += a.downloadCount;
          if (size == null || a.sizeBytes > size) size = a.sizeBytes;
        }
      }
    }

    DateTime? latestStable;
    DateTime? latestAny;
    for (final r in releases) {
      final at = r.publishedAt;
      if (at == null) continue;
      if (latestAny == null || at.isAfter(latestAny)) latestAny = at;
      if (r.prerelease) continue;
      if (latestStable == null || at.isAfter(latestStable)) latestStable = at;
    }

    final sorted = List<PluginRelease>.of(releases)
      ..sort((a, b) {
        final at = a.publishedAt;
        final bt = b.publishedAt;
        if (at == null && bt == null) return b.tag.compareTo(a.tag);
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });

    return PluginStats(
      downloadCount: count,
      latestReleaseAt: latestStable ?? latestAny,
      assetSizeBytes: size,
      releases: sorted,
      exact: matchedHits > 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'download_count': downloadCount,
        'exact': exact,
        if (latestReleaseAt != null)
          'latest_release_at': latestReleaseAt!.toIso8601String(),
        if (assetSizeBytes != null) 'asset_size': assetSizeBytes,
        if (fetchedAt != null) 'fetched_at': fetchedAt!.toIso8601String(),
        // 版本历史只留最近 12 条：SharedPreferences 里不该躺着几百个 release
        'releases': [for (final r in releases.take(12)) r.toJson()],
      };

  static PluginStats fromJson(Map<String, dynamic> json) {
    final rawReleases = json['releases'];
    final releases = <PluginRelease>[];
    if (rawReleases is List) {
      for (final r in rawReleases) {
        if (r is! Map) continue;
        final parsed = PluginRelease.fromJson(r.cast<String, dynamic>());
        if (parsed != null) releases.add(parsed);
      }
    }
    return PluginStats(
      downloadCount: _asInt(json['download_count']),
      latestReleaseAt: _asDate(json['latest_release_at']),
      assetSizeBytes:
          json['asset_size'] == null ? null : _asInt(json['asset_size']),
      fetchedAt: _asDate(json['fetched_at']),
      exact: json['exact'] == true,
      releases: releases,
    );
  }
}

/// 仓库元信息（详情页信息表里的 License / 主页 / Star）
@immutable
class PluginRepoMeta {
  const PluginRepoMeta({
    this.license,
    this.homepage,
    this.stars,
    this.pushedAt,
    this.fetchedAt,
  });

  final String? license;
  final String? homepage;
  final int? stars;

  /// 最近一次 push（没有 release 时当「最新更新」用）
  final DateTime? pushedAt;
  final DateTime? fetchedAt;

  bool isFresh(DateTime now, Duration ttl) {
    final at = fetchedAt;
    if (at == null) return false;
    return now.difference(at) < ttl;
  }

  /// 解析 `/repos/{owner}/{repo}`；看不懂返回 null。
  static PluginRepoMeta? fromRepoJson(String body, {DateTime? fetchedAt}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final json = decoded.cast<String, dynamic>();
      String? license;
      final rawLicense = json['license'];
      if (rawLicense is Map) {
        final m = rawLicense.cast<String, dynamic>();
        final spdx = (m['spdx_id'] ?? '').toString();
        final name = (m['name'] ?? '').toString();
        // NOASSERTION = GitHub 自己也认不出，等于没有
        if (spdx.isNotEmpty && spdx != 'NOASSERTION') {
          license = spdx;
        } else if (name.isNotEmpty) {
          license = name;
        }
      }
      final homepage = (json['homepage'] ?? '').toString().trim();
      return PluginRepoMeta(
        license: license,
        homepage: homepage.isEmpty ? null : homepage,
        stars: json['stargazers_count'] == null
            ? null
            : _asInt(json['stargazers_count']),
        pushedAt: _asDate(json['pushed_at']),
        fetchedAt: fetchedAt,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        if (license != null) 'license': license,
        if (homepage != null) 'homepage': homepage,
        if (stars != null) 'stars': stars,
        if (pushedAt != null) 'pushed_at': pushedAt!.toIso8601String(),
        if (fetchedAt != null) 'fetched_at': fetchedAt!.toIso8601String(),
      };

  static PluginRepoMeta fromJson(Map<String, dynamic> json) => PluginRepoMeta(
        license: json['license']?.toString(),
        homepage: json['homepage']?.toString(),
        stars: json['stars'] == null ? null : _asInt(json['stars']),
        pushedAt: _asDate(json['pushed_at']),
        fetchedAt: _asDate(json['fetched_at']),
      );
}

/// 一次批量拉取的结果
@immutable
class PluginStatsSnapshot {
  const PluginStatsSnapshot({
    this.byPluginId = const {},
    this.rateLimited = false,
    this.failure,
    this.fetchedCount = 0,
    this.cachedCount = 0,
  });

  /// 插件 id → 统计（拿不到数字的插件**不在**表里，UI 显示「—」）
  final Map<String, PluginStats> byPluginId;

  /// 撞上 GitHub 限额（未登录 60 次/小时/IP），本次提前收工
  final bool rateLimited;

  /// 第一个错误的人话描述（页面只在有内容时显示一行小字）
  final String? failure;

  final int fetchedCount;
  final int cachedCount;

  bool get isEmpty => byPluginId.isEmpty;
}

/// 插件下载量 / 版本历史客户端（v1.36）。
///
/// 数据只来自 GitHub 的公开 API（登记表不托管文件，也没有自己的统计）：
/// - `GET /repos/{owner}/{repo}/releases` → 每个 release 的
///   `assets[].download_count` 与 `published_at`（下载量 + 「最新更新」排序）；
/// - `GET /repos/{owner}/{repo}` → license / homepage（详情页信息表）。
///
/// 三条约束：
/// 1. **不阻塞页面**：请求失败只是「这一项没有数字」，绝不把异常抛给 UI；
/// 2. **一天缓存**：未登录限额 60 次/小时/IP，按插件逐个请求很容易撞上，所以结果落
///    SharedPreferences，24 小时内只读缓存（[forceRefresh] 才重拉）；
/// 3. **撞限额就停**：403 / 429 立刻放弃后续请求，把已经拿到的结果返回——
///    不能因为限额把整页数字都拖下水。
///
/// 这里用裸 [http.Client] 而不是 `SmartHttpClient`：多源镜像那套是给**文件下载**
/// 兜底的，GitHub API 没有等价镜像，套上去只会让 403/404 被重试放大。
class PluginStatsService {
  PluginStatsService({
    http.Client? client,
    this.cacheTtl = const Duration(days: 1),
    this.timeout = const Duration(seconds: 8),
  }) : _client = client;

  static final PluginStatsService instance = PluginStatsService();

  final http.Client? _client;

  /// 缓存有效期：一天（GitHub 限额按小时重置，一天一拉足够）
  final Duration cacheTtl;

  /// 单次请求超时：统计是「锦上添花」，不值得让页面等
  final Duration timeout;

  static const String cacheKey = 'plugin_stats_cache_v1';
  static const String metaCacheKey = 'plugin_repo_meta_cache_v1';

  /// 单次最多刷新多少个仓库（多出来的留给下次刷新）
  static const int maxReposPerRun = 30;

  /// 缓存条目最多留多久（再久也没意义，只会让 prefs 越来越大）
  static const Duration cacheKeep = Duration(days: 30);

  /// GitHub 要求带 UA；Accept 用官方推荐的版本化类型
  static const Map<String, String> headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Natsume-Quiz-Master (Flutter; plugin market)',
  };

  /// 插件对应的仓库坐标：优先从下载地址推，其次用登记表里的 `repo_url`
  static GitHubRepoRef? repoOf(RegistryPlugin entry) =>
      GitHubRepoRef.parse(entry.downloadUrl) ??
      GitHubRepoRef.parse(entry.repoUrl);

  /// 下载地址里的文件名（`.../releases/download/v1/x.zip` → `x.zip`）
  static String? assetNameOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final name = uri.pathSegments.last.trim();
    return name.isEmpty ? null : name;
  }

  /// 批量拉统计。[entries] 里推不出仓库的条目直接跳过（没有数字，不影响展示）。
  Future<PluginStatsSnapshot> load(
    List<RegistryPlugin> entries, {
    bool forceRefresh = false,
    DateTime? now,
  }) async {
    final clock = now ?? DateTime.now();
    final groups = <String, List<RegistryPlugin>>{};
    final refs = <String, GitHubRepoRef>{};
    for (final entry in entries) {
      final ref = repoOf(entry);
      if (ref == null) continue;
      refs[ref.slug] = ref;
      groups.putIfAbsent(ref.slug, () => <RegistryPlugin>[]).add(entry);
    }
    if (groups.isEmpty) return const PluginStatsSnapshot();

    final cached = await _readStatsCache();
    final resolved = <String, PluginStats>{...cached};
    var requests = 0;
    var fetched = 0;
    var reused = 0;
    var skipped = 0;
    var rateLimited = false;
    String? failure;

    for (final slug in groups.keys) {
      final hit = cached[slug];
      if (!forceRefresh && hit != null && hit.isFresh(clock, cacheTtl)) {
        reused++;
        continue;
      }
      if (requests >= maxReposPerRun) {
        skipped++;
        continue;
      }
      requests++;
      try {
        resolved[slug] = await _fetchReleases(
          refs[slug]!,
          groups[slug]!.first,
          clock,
        );
        fetched++;
      } on PluginStatsRateLimitException {
        // 限额了：后面的请求一律不发，手上有的先给用户看
        rateLimited = true;
        break;
      } catch (e) {
        failure ??= _describe(e);
      }
    }

    if (skipped > 0) {
      failure ??= '一次最多刷新 $maxReposPerRun 个仓库，其余下次再看';
    }
    if (fetched > 0) await _writeStatsCache(resolved, clock);

    final byPluginId = <String, PluginStats>{};
    for (final group in groups.entries) {
      final stats = resolved[group.key];
      if (stats == null) continue;
      for (final plugin in group.value) {
        byPluginId[plugin.id] = stats;
      }
    }
    return PluginStatsSnapshot(
      byPluginId: byPluginId,
      rateLimited: rateLimited,
      failure: failure,
      fetchedCount: fetched,
      cachedCount: reused,
    );
  }

  /// 拉单个仓库的元信息；失败返回缓存（可能为 null），不抛异常。
  Future<PluginRepoMeta?> loadRepoMeta(
    GitHubRepoRef ref, {
    bool forceRefresh = false,
    DateTime? now,
  }) async {
    final clock = now ?? DateTime.now();
    final cached = await _readMetaCache();
    final hit = cached[ref.slug];
    if (!forceRefresh && hit != null && hit.isFresh(clock, cacheTtl)) {
      return hit;
    }
    try {
      final res = await _get(ref.repoApi);
      final meta = PluginRepoMeta.fromRepoJson(
        utf8.decode(res.bodyBytes, allowMalformed: true),
        fetchedAt: clock,
      );
      if (meta == null) return hit;
      cached[ref.slug] = meta;
      await _writeMetaCache(cached, clock);
      return meta;
    } catch (_) {
      return hit;
    }
  }

  // ── 内部 ──

  Future<PluginStats> _fetchReleases(
    GitHubRepoRef ref,
    RegistryPlugin entry,
    DateTime clock,
  ) async {
    final res = await _get(ref.releasesApi);
    final stats = PluginStats.fromReleasesJson(
      utf8.decode(res.bodyBytes, allowMalformed: true),
      assetName: assetNameOf(entry.downloadUrl),
    );
    if (stats == null) {
      throw const FormatException('GitHub 返回的内容看不懂（也可能还没发布过）');
    }
    return stats.copyWith(fetchedAt: clock);
  }

  Future<http.Response> _get(Uri uri) async {
    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      final res = await client.get(uri, headers: headers).timeout(timeout);
      if (res.statusCode == 200) return res;
      if (_isRateLimited(res)) {
        throw const PluginStatsRateLimitException();
      }
      throw PluginStatsException('GitHub 返回 ${res.statusCode}', res.statusCode);
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// 403 一律当限额处理：GitHub 对「私有 / 被封 / 次数用完」都回 403，
  /// 继续逐个请求只会把剩下的额度一起烧掉。
  static bool _isRateLimited(http.Response res) =>
      res.statusCode == 429 || res.statusCode == 403;

  String _describe(Object error) {
    if (error is PluginStatsException) return error.message;
    if (error is TimeoutException) return '请求 GitHub 超时';
    if (error is FormatException) return error.message;
    return '请求 GitHub 失败：$error';
  }

  Future<Map<String, PluginStats>> _readStatsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final repos = decoded['repos'];
      if (repos is! Map) return {};
      final out = <String, PluginStats>{};
      repos.forEach((key, value) {
        if (key is! String || value is! Map) return;
        out[key] = PluginStats.fromJson(value.cast<String, dynamic>());
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeStatsCache(
    Map<String, PluginStats> stats,
    DateTime now,
  ) async {
    try {
      final repos = <String, dynamic>{};
      stats.forEach((slug, value) {
        final at = value.fetchedAt;
        if (at == null) return;
        if (now.difference(at) > cacheKeep) return;
        repos[slug] = value.toJson();
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cacheKey, jsonEncode({'version': 1, 'repos': repos}));
    } catch (_) {
      // 缓存写失败不影响本次展示
    }
  }

  Future<Map<String, PluginRepoMeta>> _readMetaCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(metaCacheKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final repos = decoded['repos'];
      if (repos is! Map) return {};
      final out = <String, PluginRepoMeta>{};
      repos.forEach((key, value) {
        if (key is! String || value is! Map) return;
        out[key] = PluginRepoMeta.fromJson(value.cast<String, dynamic>());
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeMetaCache(
    Map<String, PluginRepoMeta> meta,
    DateTime now,
  ) async {
    try {
      final repos = <String, dynamic>{};
      meta.forEach((slug, value) {
        final at = value.fetchedAt;
        if (at == null) return;
        if (now.difference(at) > cacheKeep) return;
        repos[slug] = value.toJson();
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        metaCacheKey,
        jsonEncode({'version': 1, 'repos': repos}),
      );
    } catch (_) {}
  }
}

/// 统计请求失败（非限额）
class PluginStatsException implements Exception {
  const PluginStatsException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

/// 撞上 GitHub 限额：立刻收工，别再发请求
class PluginStatsRateLimitException implements Exception {
  const PluginStatsRateLimitException();

  @override
  String toString() => 'GitHub API 限额已用完，请过一会儿再试';
}

// ── 小工具 ──

int _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

/// 统一存 UTC：缓存与排序都按同一时区比，避免跨时区换机器就排错
DateTime? _asDate(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.toUtc();
}

String _two(int v) => v < 10 ? '0$v' : '$v';

String _thousands(int n) {
  final text = n.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}
