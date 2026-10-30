import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_registry.dart';

/// Natsume-Registry 客户端（v1.35）：字段白名单 / 域名白名单 / sha256 / 版本比较。
///
/// 这些用例刻意不联网：登记表的**格式契约**才是客户端要守的东西，
/// 网络只负责「拿到字符串」，拿不到就保留旧列表（见 UI 层）。
void main() {
  const hex64 = '0123456789abcdef0123456789abcdef'
      '0123456789abcdef0123456789abcdef';

  Map<String, dynamic> validEntry() => {
        'id': 'weekly-stats',
        'name': '每周统计',
        'author': 'someone',
        'version': '1.0.0',
        'description': '一句话说明',
        'download_url':
            'https://github.com/someone/x/releases/download/v1.0.0/weekly-stats.zip',
        'sha256': hex64,
      };

  group('登记项字段校验', () {
    test('合法条目全部字段可读', () {
      final e = RegistryPlugin.tryParse(validEntry());
      expect(e, isNotNull);
      expect(e!.id, 'weekly-stats');
      expect(e.version, '1.0.0');
      expect(e.sha256, hex64);
      expect(e.toJson().keys.toSet(), RegistryPlugin.fieldNames);
    });

    test(r'id 必须匹配 ^[a-z0-9][a-z0-9._-]{2,63}$', () {
      for (final bad in ['ab', 'Weekly-Stats', '-weekly', '中文插件', 'a b c']) {
        final m = validEntry()..['id'] = bad;
        expect(RegistryPlugin.tryParse(m), isNull, reason: 'id=$bad 应被拒绝');
      }
      final ok = validEntry()..['id'] = 'a.b_c-d1';
      expect(RegistryPlugin.tryParse(ok), isNotNull);
    });

    test('版本必须是 x.y.z', () {
      for (final bad in ['1.0', 'v1.0.0', '1.0.0-beta', '1.0.0.0', '']) {
        final m = validEntry()..['version'] = bad;
        expect(RegistryPlugin.tryParse(m), isNull, reason: 'version=$bad');
      }
    });

    test('下载地址必须 https 且限 GitHub 系域名', () {
      for (final bad in [
        'http://github.com/a/b.zip',
        'https://evil.example.com/a.zip',
        'https://github.com.evil.com/a.zip',
        'https://raw.githubusercontent.com',
        'not a url',
      ]) {
        final m = validEntry()..['download_url'] = bad;
        expect(RegistryPlugin.tryParse(m), isNull, reason: 'url=$bad');
      }
      for (final host in RegistryPlugin.allowedHosts) {
        final m = validEntry()
          ..['download_url'] = 'https://$host/owner/repo/x.zip';
        expect(RegistryPlugin.tryParse(m), isNotNull, reason: 'host=$host');
      }
    });

    test('sha256 必须是 64 位小写十六进制', () {
      for (final bad in [
        'abc',
        hex64.toUpperCase(),
        hex64.substring(1),
        'z' * 64,
      ]) {
        final m = validEntry()..['sha256'] = bad;
        expect(RegistryPlugin.tryParse(m), isNull, reason: 'sha=$bad');
      }
    });

    test('字段多一个 / 少一个都拒绝（表结构是契约）', () {
      final extra = validEntry()..['license'] = 'MIT';
      expect(RegistryPlugin.tryParse(extra), isNull);
      final missing = validEntry()..remove('author');
      expect(RegistryPlugin.tryParse(missing), isNull);
    });

    test('说明超 240 字或空作者被拒绝', () {
      final long = validEntry()..['description'] = '字' * 241;
      expect(RegistryPlugin.tryParse(long), isNull);
      final noAuthor = validEntry()..['author'] = '  ';
      expect(RegistryPlugin.tryParse(noAuthor), isNull);
    });
  });

  group('整表解析', () {
    test('空表是合法结果（plugins: []、count: 0）', () {
      final snap = RegistrySnapshot.parse(
          '{"schema":1,"generated_at":"2026-10-30T09:08:57Z","count":0,'
          '"disclaimer":"登记不等于审核","plugins":[]}');
      expect(snap.isEmpty, isTrue);
      expect(snap.disclaimer, '登记不等于审核');
      expect(snap.generatedAt, '2026-10-30T09:08:57Z');
      expect(snap.droppedCount, 0);
    });

    test('坏条目只丢自己，好条目照常展示', () {
      final good = validEntry();
      final bad = validEntry()..['id'] = 'X';
      final snap = RegistrySnapshot.parse(
          '{"schema":1,"disclaimer":"d","plugins":'
          '[${_json(good)},${_json(bad)},${_json(validEntry()..['id'] = 'other-plugin')}]}');
      expect(snap.plugins.length, 2);
      expect(snap.droppedCount, 1);
    });

    test('plugins 不是数组 / 不是 JSON → FormatException', () {
      expect(() => RegistrySnapshot.parse('{"plugins":{}}'),
          throwsA(isA<FormatException>()));
      expect(() => RegistrySnapshot.parse('not json'),
          throwsA(isA<FormatException>()));
      expect(
          () => RegistrySnapshot.parse('[]'), throwsA(isA<FormatException>()));
    });
  });

  group('sha256 与版本比较', () {
    test('sha256Hex 与 verifySha256 一致；大小写不敏感', () {
      final bytes = [1, 2, 3, 4, 5];
      final hex = PluginRegistryService.sha256Hex(bytes);
      expect(hex.length, 64);
      expect(PluginRegistryService.verifySha256(bytes, hex), isTrue);
      expect(
          PluginRegistryService.verifySha256(bytes, hex.toUpperCase()), isTrue);
      expect(PluginRegistryService.verifySha256([9, 9, 9], hex), isFalse);
    });

    test('isNewer 按 x.y.z 逐段比较', () {
      expect(PluginRegistryService.isNewer('1.0.1', '1.0.0'), isTrue);
      expect(PluginRegistryService.isNewer('1.1.0', '1.0.9'), isTrue);
      expect(PluginRegistryService.isNewer('2.0.0', '1.99.99'), isTrue);
      expect(PluginRegistryService.isNewer('1.0.0', '1.0.0'), isFalse);
      expect(PluginRegistryService.isNewer('1.0.0', '1.0.1'), isFalse);
      // 脏版本号不猜：宁可当成「没有新版」
      expect(PluginRegistryService.isNewer('1.0', '1.0.0'), isFalse);
    });

    test('actionFor：未装 / 可更新 / 已安装', () {
      final entry = RegistryPlugin.tryParse(validEntry())!;
      expect(PluginRegistryService.actionFor(entry, null), 'install');
      expect(PluginRegistryService.actionFor(entry, _installed('0.9.0')),
          'update');
      expect(PluginRegistryService.actionFor(entry, _installed('1.0.0')),
          'installed');
      expect(PluginRegistryService.actionFor(entry, _installed('9.9.9')),
          'installed');
    });
  });
}

PluginInfo _installed(String version) => PluginInfo(
      id: 'weekly-stats',
      name: '每周统计',
      version: version,
      installedAt: '2026-10-30T00:00:00Z',
    );

String _json(Map<String, dynamic> m) {
  final parts = m.entries
      .map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}')
      .join(',');
  return '{$parts}';
}
