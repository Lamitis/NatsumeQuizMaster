import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/plugin_sort.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_registry.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_stats_service.dart';

/// 下载量统计与排序的纯逻辑（v1.36）。
///
/// 这两块都是「算错了没人看得出来」的部分，所以口径必须钉死：
/// - 下载量只数**同名发布包**；名字对不上才退回「全部 asset 之和」，并标记 `exact: false`；
/// - 排序拿不到统计时不能把插件藏起来，只是排到后面。
final String _sha = List.filled(64, 'a').join();

RegistryPlugin _entry(String id, String name, {String? version}) =>
    RegistryPlugin.tryParse({
      'id': id,
      'name': name,
      'author': 'someone',
      'version': version ?? '1.0.0',
      'description': '$name 的说明',
      'download_url':
          'https://github.com/someone/$id/releases/download/v1.0.0/$id.zip',
      'sha256': _sha,
    })!;

String _releasesJson(List<Map<String, dynamic>> releases) =>
    jsonEncode(releases);

Map<String, dynamic> _release({
  required String tag,
  String? publishedAt,
  bool prerelease = false,
  List<Map<String, dynamic>> assets = const [],
}) =>
    {
      'tag_name': tag,
      'name': tag,
      if (publishedAt != null) 'published_at': publishedAt,
      'prerelease': prerelease,
      'assets': assets,
    };

Map<String, dynamic> _asset(String name, int count, {int size = 1024}) => {
      'name': name,
      'download_count': count,
      'size': size,
    };

void main() {
  group('GitHubRepoRef', () {
    test('从 release 下载地址里抠出 owner/repo', () {
      final ref = GitHubRepoRef.parse(
          'https://github.com/someone/weekly-stats/releases/download/v1.0.0/weekly-stats.zip');
      expect(ref?.owner, 'someone');
      expect(ref?.repo, 'weekly-stats');
      expect(ref?.slug, 'someone/weekly-stats');
      expect(ref?.releasesApi.path, '/repos/someone/weekly-stats/releases');
    });

    test('raw / codeload 也认，别的域名一律不认（不猜）', () {
      expect(
        GitHubRepoRef.parse('https://raw.githubusercontent.com/a/b/main/x.json')
            ?.slug,
        'a/b',
      );
      expect(
        GitHubRepoRef.parse('https://codeload.github.com/a/b/zip/refs/heads/main')
            ?.slug,
        'a/b',
      );
      expect(GitHubRepoRef.parse('https://gitlab.com/a/b'), isNull);
      expect(GitHubRepoRef.parse('https://example.com/a/b'), isNull);
      expect(GitHubRepoRef.parse(null), isNull);
      expect(GitHubRepoRef.parse(''), isNull);
    });

    test('assetNameOf 取下载地址里的文件名', () {
      expect(
        PluginStatsService.assetNameOf(
            'https://github.com/a/b/releases/download/v1/b.zip'),
        'b.zip',
      );
      expect(PluginStatsService.assetNameOf('https://github.com/a/b'), 'b');
      expect(PluginStatsService.assetNameOf(''), isNull);
    });
  });

  group('PluginStats.fromReleasesJson', () {
    test('同名 asset 命中：只数这些，exact = true', () {
      final stats = PluginStats.fromReleasesJson(
        _releasesJson([
          _release(
            tag: 'v1.0.0',
            publishedAt: '2026-10-20T10:00:00Z',
            assets: [
              _asset('weekly-stats.zip', 100, size: 2048),
              _asset('other-plugin.zip', 9999),
            ],
          ),
        ]),
        assetName: 'weekly-stats.zip',
      );
      expect(stats, isNotNull);
      expect(stats!.downloadCount, 100, reason: '别家插件的下载量不能算进来');
      expect(stats.exact, isTrue);
      expect(stats.assetSizeBytes, 2048);
      expect(stats.downloadText, '100 次下载');
    });

    test('一个都没命中：退回全部 asset 之和，exact = false（UI 加「约」）', () {
      final stats = PluginStats.fromReleasesJson(
        _releasesJson([
          _release(tag: 'v1.0.0', assets: [
            _asset('a.zip', 300),
            _asset('b.zip', 200),
          ]),
        ]),
        assetName: 'renamed.zip',
      );
      expect(stats!.downloadCount, 500);
      expect(stats.exact, isFalse);
      expect(stats.downloadText, '约 500 次下载');
    });

    test('预发布不参与「最新更新」时间，但仍进版本历史', () {
      final stats = PluginStats.fromReleasesJson(
        _releasesJson([
          _release(
            tag: 'v2.0.0-beta',
            publishedAt: '2026-10-25T00:00:00Z',
            prerelease: true,
          ),
          _release(tag: 'v1.5.0', publishedAt: '2026-10-01T00:00:00Z'),
        ]),
      );
      expect(stats!.latestReleaseAt, DateTime.utc(2026, 10, 1));
      expect(stats.releases.first.tag, 'v2.0.0-beta', reason: '新的在前');
    });

    test('草稿 / 没有 tag / 空列表都当「没有数字」，不编 0', () {
      expect(PluginStats.fromReleasesJson('[]'), isNull);
      expect(PluginStats.fromReleasesJson('not json'), isNull);
      expect(
        PluginStats.fromReleasesJson(_releasesJson([
          {'tag_name': '', 'assets': <Map<String, dynamic>>[]},
        ])),
        isNull,
      );
      expect(
        PluginStats.fromReleasesJson(_releasesJson([
          {
            'tag_name': 'v9.9.9',
            'draft': true,
            'assets': <Map<String, dynamic>>[],
          },
        ])),
        isNull,
        reason: '草稿发布不该出现在「最新版本」里',
      );
    });
  });

  group('计数文案', () {
    test('不到一千原样，四位数加千分位，上万折算成「万」', () {
      expect(PluginStats.formatCount(0), '0');
      expect(PluginStats.formatCount(999), '999');
      expect(PluginStats.formatCount(1234), '1,234');
      expect(PluginStats.formatCount(12000), '1.2 万');
      expect(PluginStats.formatCount(10000), '1 万');
      expect(PluginStats.formatCount(-1), '—');
    });

    test('大小按 B / KB / MB 进位，没有数字就「—」', () {
      expect(PluginStats.formatBytes(null), '—');
      expect(PluginStats.formatBytes(0), '—');
      expect(PluginStats.formatBytes(512), '512 B');
      expect(PluginStats.formatBytes(831488), '812 KB');
      expect(PluginStats.formatBytes(5 * 1024 * 1024), '5.0 MB');
    });

    test('日期按本地时区写成 yyyy-MM-dd', () {
      expect(PluginStats.formatDate(null), '—');
      expect(PluginStats.formatDate(DateTime(2026, 1, 9)), '2026-01-09');
    });
  });

  group('缓存序列化', () {
    test('toJson / fromJson 往返保留下载量口径与发布时间', () {
      final stats = PluginStats(
        downloadCount: 4321,
        exact: false,
        assetSizeBytes: 2048,
        latestReleaseAt: DateTime(2026, 10, 20),
        fetchedAt: DateTime(2026, 10, 21),
        releases: [
          PluginRelease(tag: 'v1.0.0', publishedAt: DateTime(2026, 10, 20)),
        ],
      );
      final back = PluginStats.fromJson(stats.toJson());
      expect(back.downloadCount, 4321);
      expect(back.exact, isFalse, reason: '「约」的标记不能丢，否则文案会变精确');
      expect(back.assetSizeBytes, 2048);
      // 缓存统一存 UTC（跨时区比大小才不会错），所以按「同一时刻」比而不是按对象相等
      expect(back.latestReleaseAt!.isAtSameMomentAs(DateTime(2026, 10, 20)),
          isTrue);
      expect(back.releases.single.tag, 'v1.0.0');
      expect(back.isFresh(DateTime(2026, 10, 21, 12), const Duration(days: 1)),
          isTrue);
      expect(back.isFresh(DateTime(2026, 11, 1), const Duration(days: 1)),
          isFalse);
    });
  });

  group('sortRegistryPlugins', () {
    final a = _entry('a-plugin', '甲插件');
    final b = _entry('b-plugin', '乙插件');
    final c = _entry('c-plugin', '丙插件');

    test('登记表顺序：原样返回，且不改动入参', () {
      final input = [a, b, c];
      final out = sortRegistryPlugins(input, PluginSortMode.registry, const {});
      expect(out.map((e) => e.id).toList(), ['a-plugin', 'b-plugin', 'c-plugin']);
      expect(input.map((e) => e.id).toList(), ['a-plugin', 'b-plugin', 'c-plugin'],
          reason: '不能就地排序，调用方还要用原列表');
    });

    test('下载最多：降序；没有统计的排最后而不是被藏掉', () {
      final out = sortRegistryPlugins([a, b, c], PluginSortMode.downloads, {
        'a-plugin': const PluginStats(downloadCount: 10, exact: true),
        'b-plugin': const PluginStats(downloadCount: 900, exact: true),
      });
      expect(out.map((e) => e.id).toList(),
          ['b-plugin', 'a-plugin', 'c-plugin']);
    });

    test('最新更新：时间新的在前，没有时间的排最后', () {
      final out = sortRegistryPlugins([a, b, c], PluginSortMode.latest, {
        'a-plugin': PluginStats(downloadCount: 0, latestReleaseAt: DateTime(2026, 1, 1)),
        'b-plugin': PluginStats(downloadCount: 0, latestReleaseAt: DateTime(2026, 10, 1)),
      });
      expect(out.map((e) => e.id).toList(),
          ['b-plugin', 'a-plugin', 'c-plugin']);
    });

    test('parse 认不出就退回默认排序，不抛异常', () {
      expect(PluginSortMode.parse('downloads'), PluginSortMode.downloads);
      expect(PluginSortMode.parse('乱写的'), PluginSortMode.latest);
      expect(PluginSortMode.parse(null), PluginSortMode.latest);
    });
  });
}
