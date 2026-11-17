import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:natsume_quiz_master/services/net/smart_http_client.dart';
import 'package:natsume_quiz_master/services/update_service.dart';

/// v1.39.2 应用内更新：流式落盘、多源回退、进度与安装器兜底。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_update_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  UpdateCheckResult updateFor(String url) => UpdateCheckResult(
        status: UpdateStatus.updateAvailable,
        currentVersion: 'v1.39.1',
        latestVersion: 'v1.39.2',
        downloadUrl: url,
        downloadFileName: Uri.parse(url).pathSegments.last,
      );

  test('downloadUpdate：流式落盘并回报百分比 / 速度', () async {
    // APK 必须是 ZIP 头（PK），否则新的文件头校验会（正确地）拒绝
    final payload = <int>[
      ...utf8.encode('PK\u0003\u0004'),
      ...utf8.encode('fake-apk-content' * 200),
    ];
    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      return http.StreamedResponse(
        Stream.fromIterable([
          payload.sublist(0, 64),
          payload.sublist(64),
        ]),
        200,
        contentLength: payload.length,
      );
    });
    final progress = <UpdateDownloadProgress>[];
    final result = await UpdateService.downloadUpdate(
      update: updateFor(
          'https://github.com/owner/repo/releases/download/v1.39.2/app.apk'),
      smartClient: SmartHttpClient(client: client),
      saveDir: tmp.path,
      platform: UpdatePlatform.android,
      onProgress: progress.add,
    );

    expect(progress, isNotEmpty);
    expect(progress.last.receivedBytes, payload.length);
    expect(progress.last.percent, 100);
    expect(progress.last.bytesPerSecond, greaterThanOrEqualTo(0));
    final file = File(result.filePath);
    expect(file.existsSync(), isTrue);
    // v1.42.1：必须是正式后缀，且不能残留 .part
    expect(result.filePath.toLowerCase().endsWith('.apk'), isTrue);
    expect(File('${result.filePath}.part').existsSync(), isFalse);
    expect(await file.readAsBytes(), payload);
    expect(result.bytes, payload.length);
  });

  test('downloadUpdate：第一个源 500 时自动换加速源，半截文件不残留', () async {
    final payload = <int>[
      ...utf8.encode('PK\u0003\u0004'),
      ...utf8.encode('apk-from-accelerator'),
    ];
    var hits = 0;
    final client = MockClient.streaming((request, bodyStream) async {
      hits++;
      await bodyStream.drain<void>();
      if (request.url.host == 'github.com') {
        return http.StreamedResponse(const Stream.empty(), 500);
      }
      return http.StreamedResponse(
        Stream.value(payload),
        200,
        contentLength: payload.length,
      );
    });

    final result = await UpdateService.downloadUpdate(
      update: updateFor(
          'https://github.com/owner/repo/releases/download/v1.39.2/app.apk'),
      smartClient: SmartHttpClient(client: client),
      saveDir: tmp.path,
      platform: UpdatePlatform.android,
    );

    expect(hits, greaterThan(1));
    expect(result.sourceLabel, contains('加速'));
    expect(await File(result.filePath).readAsBytes(), payload);
  });

  test('downloadUpdate：全部源失败抛出带原始链接的异常', () async {
    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      return http.StreamedResponse(const Stream.empty(), 500);
    });
    const url =
        'https://github.com/owner/repo/releases/download/v1.39.2/app.apk';
    await expectLater(
      UpdateService.downloadUpdate(
        update: updateFor(url),
        smartClient: SmartHttpClient(client: client),
        saveDir: tmp.path,
        platform: UpdatePlatform.android,
      ),
      throwsA(isA<UpdateDownloadException>()
          .having((e) => e.downloadUrl, 'downloadUrl', url)),
    );
  });

  test('downloadUpdate：镜像目录页不是安装包，直接提示复制链接', () async {
    await expectLater(
      UpdateService.downloadUpdate(
        update: updateFor(UpdateService.mirrorTagUrl('v1.39.2')),
        saveDir: tmp.path,
      ),
      throwsA(isA<UpdateDownloadException>()),
    );
  });

  test('installUpdate：安装器启动结果透传（可用注入避免真拉起）', () async {
    final file = File('${tmp.path}/setup.exe')..writeAsStringSync('x');
    final download = UpdateDownloadResult(
      filePath: file.path,
      downloadUrl: 'https://example.com/setup.exe',
      sourceLabel: '原始',
      bytes: 1,
    );
    expect(
      await UpdateService.installUpdate(download,
          openInstaller: (_) async => true),
      isTrue,
    );
    expect(
      await UpdateService.installUpdate(download,
          openInstaller: (_) async => false),
      isFalse,
    );
  });

  // ═══════════ v1.42.1：下载完整性 / 哈希校验 / 平台严选 ═══════════

  test('downloadUpdate：平台不符（Windows 收到 apk）在下载前就拒绝', () async {
    await expectLater(
      UpdateService.downloadUpdate(
        update: updateFor('https://x/app.apk'),
        saveDir: tmp.path,
        platform: UpdatePlatform.windows,
      ),
      throwsA(isA<UpdateDownloadException>()
          .having((e) => e.message, 'message', contains('只支持'))),
    );
  });

  test('downloadUpdate：HTML 劫持页被文件头校验拦下，且不留下安装包', () async {
    final html = utf8.encode('<html><body>运营商广告</body></html>');
    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      return http.StreamedResponse(Stream.value(html), 200,
          contentLength: html.length);
    });
    await expectLater(
      UpdateService.downloadUpdate(
        update: updateFor(
            'https://github.com/owner/repo/releases/download/v1.39.2/app.apk'),
        smartClient: SmartHttpClient(client: client),
        saveDir: tmp.path,
        platform: UpdatePlatform.android,
      ),
      throwsA(isA<UpdateDownloadException>()
          .having((e) => e.message, 'message', contains('不是有效'))),
    );
    expect(_installerLeftovers(tmp), isEmpty);
  });

  test('downloadUpdate：SHA-256 匹配时标记已校验并落成 .apk', () async {
    final payload = <int>[
      ...utf8.encode('PK\u0003\u0004'),
      ...utf8.encode('checked-apk'),
    ];
    final digest = sha256.convert(payload).toString();
    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      if (request.url.path.endsWith('SHA256SUMS.txt')) {
        final text = utf8.encode('$digest  app.apk\n');
        return http.StreamedResponse(Stream.value(text), 200,
            contentLength: text.length);
      }
      return http.StreamedResponse(Stream.value(payload), 200,
          contentLength: payload.length);
    });
    final result = await UpdateService.downloadUpdate(
      update: const UpdateCheckResult(
        status: UpdateStatus.updateAvailable,
        currentVersion: 'v1.39.1',
        latestVersion: 'v1.39.2',
        downloadUrl:
            'https://github.com/owner/repo/releases/download/v1.39.2/app.apk',
        downloadFileName: 'app.apk',
        checksumUrl:
            'https://github.com/owner/repo/releases/download/v1.39.2/SHA256SUMS.txt',
      ),
      smartClient: SmartHttpClient(client: client),
      saveDir: tmp.path,
      platform: UpdatePlatform.android,
    );
    expect(result.checksumVerified, isTrue);
    expect(result.filePath.toLowerCase().endsWith('.apk'), isTrue);
    expect(File('${result.filePath}.part').existsSync(), isFalse);
    expect(await File(result.filePath).readAsBytes(), payload);
  });

  test('downloadUpdate：SHA-256 不匹配时报错并删除文件', () async {
    final payload = <int>[
      ...utf8.encode('PK\u0003\u0004'),
      ...utf8.encode('tampered'),
    ];
    final wrong = '0' * 64;
    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      if (request.url.path.endsWith('SHA256SUMS.txt')) {
        final text = utf8.encode('$wrong  app.apk\n');
        return http.StreamedResponse(Stream.value(text), 200,
            contentLength: text.length);
      }
      return http.StreamedResponse(Stream.value(payload), 200,
          contentLength: payload.length);
    });
    await expectLater(
      UpdateService.downloadUpdate(
        update: const UpdateCheckResult(
          status: UpdateStatus.updateAvailable,
          currentVersion: 'v1.39.1',
          latestVersion: 'v1.39.2',
          downloadUrl:
              'https://github.com/owner/repo/releases/download/v1.39.2/app.apk',
          downloadFileName: 'app.apk',
          checksumUrl:
              'https://github.com/owner/repo/releases/download/v1.39.2/SHA256SUMS.txt',
        ),
        smartClient: SmartHttpClient(client: client),
        saveDir: tmp.path,
        platform: UpdatePlatform.android,
      ),
      throwsA(isA<UpdateDownloadException>()
          .having((e) => e.message, 'message', contains('SHA-256 校验失败'))),
    );
    expect(_installerLeftovers(tmp), isEmpty);
  });

  test('looksLikeInstaller：APK=PK，EXE=MZ，HTML 拒绝', () async {
    final apk = File('${tmp.path}/a.apk')
      ..writeAsBytesSync(<int>[0x50, 0x4B, 0, 0]);
    final exe = File('${tmp.path}/a.exe')
      ..writeAsBytesSync(<int>[0x4D, 0x5A, 0, 0]);
    final html = File('${tmp.path}/h.apk')..writeAsStringSync('<html>');
    expect(await UpdateService.looksLikeInstaller(apk.path, '.apk'), isTrue);
    expect(await UpdateService.looksLikeInstaller(exe.path, '.exe'), isTrue);
    expect(await UpdateService.looksLikeInstaller(html.path, '.apk'), isFalse);
  });
}

/// 下载目录里是否还残留安装包 / .part（校验失败必须清干净）
List<File> _installerLeftovers(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((f) =>
        f.path.contains('NatsumeQuizMaster') &&
        (f.path.endsWith('.apk') ||
            f.path.endsWith('.exe') ||
            f.path.endsWith('.part')))
    .toList();
