import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/services/net/smart_http_client.dart';

/// v1.36 网络加速：多源回退 / 自定义镜像 / 逐源 sha256。
///
/// 这些用例刻意不联网：真正要钉死的是「第一个源挂了会发生什么」。
/// 真机上被墙、镜像 502、镜像给了个坏包，靠手点是试不出来的。
void main() {
  const registryBody = '{"schema":1,"plugins":[]}';
  const zipUrl =
      'https://github.com/someone/x/releases/download/v1.0.0/weekly-stats.zip';

  group('候选池', () {
    test('登记表：原始 → jsDelivr → 4 个加速，共 6 个源', () {
      final sources = SmartHttpClient.registryCandidates();
      final urls = sources.map((s) => s.url).toList();
      expect(urls.length, 6);
      expect(urls.first, SmartHttpClient.registryRawUrl);
      expect(urls[1], SmartHttpClient.registryJsDelivrUrl);
      expect(
          urls.last, 'https://ghproxy.net/${SmartHttpClient.registryRawUrl}');
      // 顺序就是回退顺序：每个加速源都排在自己该在的位置
      expect(urls[2], startsWith('https://ghfast.top/'));
      expect(urls[3], startsWith('https://gh-proxy.com/'));
      expect(urls[4], startsWith('https://gh.llkk.cc/'));
    });

    test('自定义镜像排最前，前缀自动补尾斜杠', () {
      final sources =
          SmartHttpClient.registryCandidates(customMirror: 'https://my.proxy');
      expect(sources.first.label, '自定义镜像');
      expect(sources.first.url,
          'https://my.proxy/${SmartHttpClient.registryRawUrl}');
      expect(sources.length, 7);
    });

    test('自定义镜像支持 {url} 模板（原地址会被 URL 编码）', () {
      final applied = SmartHttpClient.applyCustomMirror(
        'https://my.proxy/?url={url}',
        zipUrl,
      );
      expect(applied, 'https://my.proxy/?url=${Uri.encodeComponent(zipUrl)}');
    });

    test('下载：原始 → 4 个加速；非 GitHub 链接不套加速前缀', () {
      final github = SmartHttpClient.downloadCandidates(zipUrl);
      expect(github.map((s) => s.url).toList(), [
        zipUrl,
        'https://ghfast.top/$zipUrl',
        'https://gh-proxy.com/$zipUrl',
        'https://gh.llkk.cc/$zipUrl',
        'https://ghproxy.net/$zipUrl',
      ]);

      final other =
          SmartHttpClient.downloadCandidates('https://example.com/a.zip');
      expect(other.map((s) => s.url).toList(), ['https://example.com/a.zip']);
    });

    test('isGitHubUrl 只认 https 的 GitHub 系域名', () {
      expect(SmartHttpClient.isGitHubUrl(zipUrl), isTrue);
      expect(
          SmartHttpClient.isGitHubUrl(
              'https://objects.githubusercontent.com/a.zip'),
          isTrue);
      expect(SmartHttpClient.isGitHubUrl('https://example.com/a.zip'), isFalse);
      expect(SmartHttpClient.isGitHubUrl('http://github.com/a.zip'), isFalse);
    });
  });

  group('登记表多源回退', () {
    test('第一个源 500 时自动换到 jsDelivr', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'raw.githubusercontent.com') {
          return http.Response('boom', 500);
        }
        if (req.url.host == 'cdn.jsdelivr.net') {
          return http.Response(registryBody, 200);
        }
        return http.Response('nope', 404);
      });

      final result = await SmartHttpClient(client: client).fetchRegistry();
      expect(result.text, registryBody);
      expect(result.label, 'jsDelivr');
      expect(result.attempts.first.statusCode, 500);
      expect(result.attempts.first.ok, isFalse);
    });

    test('超时的源会被跳过，继续试下一个', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'raw.githubusercontent.com') {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        return http.Response(registryBody, 200);
      });

      final result = await SmartHttpClient(client: client)
          .fetchRegistry(timeout: const Duration(milliseconds: 20));
      expect(result.label, 'jsDelivr');
      expect(result.attempts.first.error, contains('超时'));
    });

    test('每个源都带上 User-Agent（GitHub 不给 UA 会 403）', () async {
      final client = MockClient((req) async {
        expect(req.headers['User-Agent'], SmartHttpClient.userAgent);
        expect(req.headers['Accept'], 'application/json');
        return http.Response(registryBody, 200);
      });

      await SmartHttpClient(client: client).fetchRegistry();
    });

    test('200 但返回 HTML 拦截页：继续换下一个源', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'raw.githubusercontent.com') {
          return http.Response('<html>blocked</html>', 200);
        }
        return http.Response(registryBody, 200);
      });

      final result = await SmartHttpClient(client: client).fetchRegistry();
      expect(result.label, 'jsDelivr');
      expect(result.attempts.first.statusCode, 200);
      expect(result.attempts.first.error, contains('拦截页'));
    });

    test('全部失败：抛异常并保留 6 条原因', () async {
      final client = MockClient((req) async => http.Response('down', 502));

      try {
        await SmartHttpClient(client: client).fetchRegistry();
        fail('应当抛 SmartHttpException');
      } on SmartHttpException catch (e) {
        expect(e.attempts.length, 6);
        expect(e.message, contains('已尝试 6 个源'));
        expect(e.attempts.every((a) => a.statusCode == 502), isTrue);
        expect(e.originalUrl, SmartHttpClient.registryRawUrl);
      }
    });

    test('自定义镜像优先：命中后不再请求其它源', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.toString());
        return http.Response(registryBody, 200);
      });

      final result = await SmartHttpClient(
        client: client,
        customMirror: 'https://my.proxy/',
      ).fetchRegistry();
      expect(result.label, '自定义镜像');
      expect(hits, ['https://my.proxy/${SmartHttpClient.registryRawUrl}']);
    });
  });

  group('插件包下载与 sha256', () {
    final good = utf8.encode('plugin-zip-bytes');
    final goodHex = sha256.convert(good).toString();

    test('原始源给了坏包 → 丢弃并换到加速源', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'github.com') {
          return http.Response.bytes(utf8.encode('tampered'), 200);
        }
        if (req.url.host == 'ghfast.top') {
          return http.Response.bytes(good, 200);
        }
        return http.Response('nope', 404);
      });

      final result = await SmartHttpClient(client: client)
          .downloadVerified(url: zipUrl, expectedSha256: goodHex);
      expect(result.bytes, good);
      expect(result.label, '加速·ghfast.top');
      expect(result.attempts.first.error, contains('sha256 不匹配'));
    });

    test('sha256 大小写不敏感', () async {
      final client = MockClient((req) async => http.Response.bytes(good, 200));
      final result = await SmartHttpClient(client: client).downloadVerified(
        url: zipUrl,
        expectedSha256: goodHex.toUpperCase(),
      );
      expect(result.label, '原始');
    });

    test('所有源都给坏包：拒绝安装并保留原始下载地址', () async {
      final client = MockClient(
          (req) async => http.Response.bytes(utf8.encode('evil'), 200));

      try {
        await SmartHttpClient(client: client)
            .downloadVerified(url: zipUrl, expectedSha256: goodHex);
        fail('应当抛 SmartHttpException');
      } on SmartHttpException catch (e) {
        expect(e.attempts.length, 5);
        expect(e.message, contains('校验不通过'));
        expect(e.originalUrl, zipUrl);
        expect(e.attempts.every((a) => a.error!.contains('sha256')), isTrue);
      }
    });

    test('自定义镜像优先用于下载', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'my.proxy');
        return http.Response.bytes(good, 200);
      });

      final result = await SmartHttpClient(
        client: client,
        customMirror: 'https://my.proxy',
      ).downloadVerified(url: zipUrl, expectedSha256: goodHex);
      expect(result.label, '自定义镜像');
      expect(result.url, 'https://my.proxy/$zipUrl');
    });
  });

  group('设置往返', () {
    test('custom_mirror 随 toMap / fromMap 往返；老备份缺键为空', () {
      final s = AppSettings(customMirror: 'https://my.proxy/');
      expect(s.toMap()['custom_mirror'], 'https://my.proxy/');
      expect(AppSettings.fromMap(s.toMap()).customMirror, 'https://my.proxy/');
      // 老备份没有这个键 → 空 = 只用内置池，不报错
      expect(AppSettings.fromMap(const {}).customMirror, '');
      // copyWith 只改镜像，别把别的设置一起清掉
      final cleared = s.copyWith(customMirror: '');
      expect(cleared.customMirror, '');
      expect(cleared.model, s.model);
    });
  });
}
