import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:natsume_quiz_master/services/update_service.dart';
import 'package:natsume_quiz_master/utils/app_constants.dart';

/// 检查更新（v1.34）：版本比较 + 清华镜像解析 + 下载链接挑选 + 失败降级。
///
/// 为什么这些必须是纯函数测试：更新链路的两端都在外面（镜像站、GitHub API），
/// 真机上断网/限流时才会暴露的问题，靠手点根本发现不了。这里把「版本号谁更新」
/// 「镜像目录里哪个 tag 最新」「哪个资产该下」都钉死，网络部分用 MockClient 替身。
void main() {
  /// 清华镜像首页的真实形态：Apache 目录列表，目录按字典序排列
  /// （`v1.9.0` 排在 `v1.33.0.26` **后面**，正好用来防止「取第一个」的写法）
  const mirrorIndexHtml = '''
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html><head><title>Index of /github-release/Lamitis/NatsumeQuizMaster/</title></head>
<body>
<h1>Index of /github-release/Lamitis/NatsumeQuizMaster/</h1>
<pre>      <a href="?C=N;O=D">Name</a> <a href="?C=M;O=A">Last modified</a>
<hr><pre>
      <a href="../">Parent Directory</a>                        -
      <a href="v1.9.0/">v1.9.0/</a>                             2025-06-01 10:00  -
      <a href="v1.33.0.26/">v1.33.0.26/</a>                   2026-01-08 10:00  -
      <a href="v1.34.0/">v1.34.0/</a>                         2026-10-20 10:00  -
      <a href="README.md">README.md</a>                        2026-01-08 10:00  1K
</pre><hr></body></html>
''';

  group('版本比较', () {
    test('逐段比数字：构建号更大也算更新', () {
      expect(UpdateService.compareVersions('v1.34.0.1', 'v1.34.0'),
          greaterThan(0));
      expect(
          UpdateService.compareVersions('v1.34.0', 'v1.34.0.1'), lessThan(0));
      expect(UpdateService.compareVersions('v1.34.0.1', 'v1.34.0.1'), 0);
      // 缺的段按 0 补：v1.34 == v1.34.0 == v1.34.0.0
      expect(UpdateService.compareVersions('v1.34', 'v1.34.0.0'), 0);
    });

    test('前导 v / V 与纯数字写法等价', () {
      expect(UpdateService.compareVersions('1.34.0', 'v1.34.0'), 0);
      expect(
          UpdateService.compareVersions('V1.35.0', 'v1.34.9'), greaterThan(0));
    });

    test('预发布比同号正式版旧（不能把 rc 当正式版推给用户）', () {
      expect(
          UpdateService.compareVersions('v1.34.0-rc1', 'v1.34.0'), lessThan(0));
      expect(UpdateService.compareVersions('v1.34.0', 'v1.34.0-rc1'),
          greaterThan(0));
      // 但比上一版正式版还是新
      expect(UpdateService.compareVersions('v1.34.0-rc1', 'v1.33.0'),
          greaterThan(0));
    });

    test('版本号切段：非数字段按 0 处理，不抛异常', () {
      expect(UpdateService.versionParts('v1.33.0.26'), [1, 33, 0, 26]);
      expect(UpdateService.versionParts('v1.34.0-rc1'), [1, 34, 0]);
      expect(UpdateService.versionParts('v1.34.0+build7'), [1, 34, 0]);
      expect(UpdateService.versionParts(''), [0]);
    });

    test('目录名是否像版本号', () {
      expect(UpdateService.isVersionLike('v1.33.0'), isTrue);
      expect(UpdateService.isVersionLike('1.33.0.26'), isTrue);
      expect(UpdateService.isVersionLike('v1.34.0-rc1'), isTrue);
      expect(UpdateService.isVersionLike('../'), isFalse);
      expect(UpdateService.isVersionLike('README.md'), isFalse);
      expect(UpdateService.isVersionLike(''), isFalse);
    });
  });

  group('清华镜像目录解析', () {
    test('按版本大小取最新，而不是按目录里的先后顺序', () {
      // 字典序最大的是 v1.9.0（"9" > "3"），版本序最大的是 v1.34.0
      expect(
          UpdateService.latestTagFromMirrorIndex(mirrorIndexHtml), 'v1.34.0');
    });

    test('忽略父目录、绝对链接与非版本目录', () {
      const html = '<a href="../">Parent</a>'
          '<a href="/github-release/">上级</a>'
          '<a href="https://example.com/">外链</a>'
          '<a href="plugins/">plugins/</a>'
          '<a href="v1.30.0/">v1.30.0/</a>';
      expect(UpdateService.latestTagFromMirrorIndex(html), 'v1.30.0');
    });

    test('一个版本目录都没有时返回 null（交给 GitHub 兜底）', () {
      expect(
          UpdateService.latestTagFromMirrorIndex('<a href="README.md">x</a>'),
          isNull);
      expect(UpdateService.latestTagFromMirrorIndex(''), isNull);
    });

    test('tag 目录页地址拼在镜像首页后面', () {
      expect(UpdateService.mirrorTagUrl('v1.34.0'),
          '${UpdateService.mirrorIndexUrl}v1.34.0/');
    });
  });

  group('下载链接挑选', () {
    test('没有资产时退回发布页', () {
      expect(UpdateService.pickDownloadUrl(assets: null),
          UpdateService.releasesPage);
      expect(UpdateService.pickDownloadUrl(assets: const []),
          UpdateService.releasesPage);
    });

    test('Android 只挑 apk：zip / SHA256SUMS.txt / md5 一律跳过', () {
      final picked = UpdateService.pickDownloadAsset(
        platform: UpdatePlatform.android,
        assets: [
          {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://x/sums'},
          {
            'name': 'natsume.zip',
            'browser_download_url': 'https://x/bundle.zip'
          },
          {
            'name': 'natsume.apk.md5',
            'browser_download_url': 'https://x/apk.md5'
          },
          {
            'name': 'natsume.apk',
            'browser_download_url': 'https://x/natsume.apk'
          },
          {'name': 'notes.txt', 'browser_download_url': 'https://x/notes.txt'},
        ],
      );
      expect(picked.url, 'https://x/natsume.apk');
      expect(picked.name, 'natsume.apk');
    });

    test('Android 只有 zip / 校验文件时退回发布页（绝不下载 zip）', () {
      final url = UpdateService.pickDownloadUrl(
        platform: UpdatePlatform.android,
        assets: [
          {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://x/sums'},
          {
            'name': 'bundle.zip',
            'browser_download_url': 'https://x/bundle.zip'
          },
        ],
      );
      expect(url, UpdateService.releasesPage);
    });

    test('Windows 只挑 exe：apk / zip / SHA256SUMS.txt 一律跳过', () {
      final picked = UpdateService.pickDownloadAsset(
        platform: UpdatePlatform.windows,
        assets: [
          {
            'name': 'natsume.apk',
            'browser_download_url': 'https://x/natsume.apk'
          },
          {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://x/sums'},
          {
            'name': 'bundle.zip',
            'browser_download_url': 'https://x/bundle.zip'
          },
          {
            'name': 'natsume-setup.exe',
            'browser_download_url': 'https://x/setup.exe'
          },
        ],
      );
      expect(picked.url, 'https://x/setup.exe');
      expect(picked.name, 'natsume-setup.exe');
    });

    test('全是未知格式时退回发布页，而不是把说明文件当安装包', () {
      final url = UpdateService.pickDownloadUrl(
        platform: UpdatePlatform.android,
        assets: [
          {'name': 'license', 'browser_download_url': 'https://x/license'},
        ],
      );
      expect(url, UpdateService.releasesPage);
    });

    test('资产缺少直链时跳过（不能返回空串）', () {
      final url = UpdateService.pickDownloadUrl(
        platform: UpdatePlatform.android,
        assets: [
          {'name': 'broken.apk'},
          {'name': 'ok.apk', 'browser_download_url': 'https://x/ok.apk'},
        ],
      );
      expect(url, 'https://x/ok.apk');
    });

    test('资产名缺失时按 URL 末段判断类型', () {
      final picked = UpdateService.pickDownloadAsset(
        platform: UpdatePlatform.windows,
        assets: [
          {'browser_download_url': 'https://x/download/setup.exe?token=1'},
        ],
      );
      expect(picked.url, 'https://x/download/setup.exe?token=1');
      expect(picked.name, 'setup.exe');
    });

    test('isInstallerForPlatform：apk / exe 严格分平台', () {
      expect(
          UpdateService.isInstallerForPlatform(
              'https://x/a.apk', UpdatePlatform.android),
          isTrue);
      expect(
          UpdateService.isInstallerForPlatform(
              'https://x/a.apk', UpdatePlatform.windows),
          isFalse);
      expect(
          UpdateService.isInstallerForPlatform(
              'https://x/a.exe?x=1', UpdatePlatform.windows),
          isTrue);
      expect(
          UpdateService.isInstallerForPlatform(
              'SHA256SUMS.txt', UpdatePlatform.android),
          isFalse);
      expect(
          UpdateService.isInstallerForPlatform(
              'bundle.zip', UpdatePlatform.android),
          isFalse);
    });
    test('安装包类型识别：只认 apk / exe，镜像目录页不可应用内安装', () {
      expect(UpdateService.installerExtension('https://x/a.apk'), '.apk');
      expect(UpdateService.installerExtension('https://x/a.exe'), '.exe');
      expect(
          UpdateService.installerExtension(
              'https://x/releases/download/v1.0.0/installer', 'installer.exe'),
          '.exe');
      expect(UpdateService.installerExtension('https://x/bundle.zip'), isNull);
      expect(
          UpdateService.installerExtension(
              UpdateService.mirrorTagUrl('v1.39.2')),
          isNull);
    });

    test('canInstallInApp：Windows 只接受 exe，Android 只接受 apk', () {
      UpdateCheckResult result(String url) => UpdateCheckResult(
            status: UpdateStatus.updateAvailable,
            currentVersion: 'v1.39.1',
            latestVersion: 'v1.39.2',
            downloadUrl: url,
          );
      final apk = result('https://x/app.apk');
      final exe = result('https://x/setup.exe');
      expect(
          UpdateService.canInstallInApp(apk, platform: UpdatePlatform.android),
          isTrue);
      expect(
          UpdateService.canInstallInApp(exe, platform: UpdatePlatform.android),
          isFalse);
      expect(
          UpdateService.canInstallInApp(apk, platform: UpdatePlatform.windows),
          isFalse);
      expect(
          UpdateService.canInstallInApp(exe, platform: UpdatePlatform.windows),
          isTrue);
      expect(UpdateService.canInstallInApp(apk, platform: UpdatePlatform.other),
          isFalse);
    });

    test('校验文件挑选：优先 SHA256SUMS.txt，其次 .sha256', () {
      final exact = UpdateService.pickChecksumAsset(assets: [
        {'name': 'natsume.apk', 'browser_download_url': 'https://x/app.apk'},
        {
          'name': 'SHA256SUMS.txt',
          'browser_download_url': 'https://x/SHA256SUMS.txt',
        },
      ]);
      expect(exact.url, 'https://x/SHA256SUMS.txt');
      expect(exact.name, 'SHA256SUMS.txt');

      final sha = UpdateService.pickChecksumAsset(assets: [
        {
          'name': 'app.apk.sha256',
          'browser_download_url': 'https://x/app.sha256',
        },
      ]);
      expect(sha.url, 'https://x/app.sha256');
      expect(UpdateService.pickChecksumAsset(assets: const []).url, isEmpty);
    });

    test('SHA256SUMS 解析：支持路径前缀与 * 标记，按文件名匹配', () {
      const a =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const b =
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
      const text = '$a  dist/natsume.apk\n$b *setup.exe\n';
      expect(UpdateService.parseChecksum(text, 'natsume.apk'), a);
      expect(UpdateService.parseChecksum(text, 'https://x/download/setup.exe'),
          b.toLowerCase());
      expect(UpdateService.parseChecksum(text, 'missing.apk'), isNull);
      expect(
          UpdateService.parseChecksum('not a checksum file', 'a.apk'), isNull);
    });
  });

  group('check()：镜像优先，GitHub 兜底', () {
    test('镜像确认已是最新时不再请求 GitHub', () async {
      var githubHits = 0;
      final client = MockClient((req) async {
        if (req.url.host == 'mirrors.tuna.tsinghua.edu.cn') {
          return http.Response.bytes(utf8.encode(mirrorIndexHtml), 200);
        }
        githubHits++;
        return http.Response('{}', 200);
      });

      final r =
          await UpdateService.check(client: client, currentVersion: 'v1.34.0');
      expect(r.status, UpdateStatus.upToDate);
      expect(r.source, '清华镜像');
      expect(r.latestVersion, 'v1.34.0');
      expect(r.downloadUrl, UpdateService.mirrorTagUrl('v1.34.0'));
      expect(githubHits, 0);
    });

    test('镜像发现更新后经 GitHub API 拿资产直链与说明', () async {
      var githubHits = 0;
      final client = MockClient((req) async {
        if (req.url.host == 'mirrors.tuna.tsinghua.edu.cn') {
          return http.Response.bytes(utf8.encode(mirrorIndexHtml), 200);
        }
        githubHits++;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'tag_name': 'v1.34.0',
            'body': '应用内更新',
            'assets': [
              {
                'name': 'natsume-v1.34.0.apk',
                'browser_download_url': 'https://dl/natsume.apk',
              },
            ],
          })),
          200,
        );
      });

      final r = await UpdateService.check(
          client: client,
          currentVersion: 'v1.33.0.26',
          platform: UpdatePlatform.android);
      expect(r.status, UpdateStatus.updateAvailable);
      expect(r.source, 'GitHub');
      expect(r.latestVersion, 'v1.34.0');
      expect(r.downloadUrl, 'https://dl/natsume.apk');
      expect(r.downloadFileName, 'natsume-v1.34.0.apk');
      expect(r.notes, '应用内更新');
      expect(githubHits, 1);
    });

    test('本地已是最新时不误报更新', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'mirrors.tuna.tsinghua.edu.cn') {
          return http.Response.bytes(utf8.encode(mirrorIndexHtml), 200);
        }
        return http.Response('{}', 500);
      });

      final r =
          await UpdateService.check(client: client, currentVersion: 'v1.34.0');
      expect(r.status, UpdateStatus.upToDate);
      expect(r.hasUpdate, isFalse);
      expect(r.latestVersion, 'v1.34.0');
    });

    test('镜像挂了改走 GitHub，并带上资产直链与发布说明', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'mirrors.tuna.tsinghua.edu.cn') {
          return http.Response('boom', 502);
        }
        expect(req.headers['User-Agent'], isNotNull,
            reason: 'GitHub API 不给 UA 会 403');
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'tag_name': 'v1.35.0',
            'html_url':
                'https://github.com/Lamitis/NatsumeQuizMaster/releases/tag/v1.35.0',
            'body': '补了日程插件',
            'assets': [
              {
                'name': 'natsume-quiz-master-v1.35.0.apk',
                'browser_download_url': 'https://dl/natsume.apk',
              },
            ],
          })),
          200,
        );
      });

      final r = await UpdateService.check(
          client: client,
          currentVersion: 'v1.34.0',
          platform: UpdatePlatform.android);
      expect(r.status, UpdateStatus.updateAvailable);
      expect(r.source, 'GitHub');
      expect(r.latestVersion, 'v1.35.0');
      expect(r.downloadUrl, 'https://dl/natsume.apk');
      expect(r.notes, '补了日程插件');
    });

    test('两路都失败时返回失败结果，说明两路原因且不抛异常', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'mirrors.tuna.tsinghua.edu.cn') {
          return http.Response('down', 500);
        }
        return http.Response('rate limited', 403);
      });

      final r =
          await UpdateService.check(client: client, currentVersion: 'v1.34.0');
      expect(r.status, UpdateStatus.failed);
      expect(r.failed, isTrue);
      expect(r.error, contains('清华镜像'));
      expect(r.error, contains('GitHub'));
      expect(r.downloadUrl, isNull);
    });

    test('默认当前版本取自 kAppVersion（版本号只有一处来源）', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'mirrors.tuna.tsinghua.edu.cn') {
          return http.Response('down', 500);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'tag_name': 'v0.0.1', 'assets': const []})),
          200,
        );
      });

      final r = await UpdateService.check(client: client);
      expect(r.currentVersion, kAppVersion);
      // 远端比本地旧 ⇒ 不提示更新（开发中构建号常常比线上大）
      expect(r.status, UpdateStatus.upToDate);
    });
  });
}
