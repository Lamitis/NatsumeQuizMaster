import 'dart:convert';
import 'dart:io';

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
    final payload = utf8.encode('fake-apk-content' * 200);
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
      onProgress: progress.add,
    );

    expect(progress, isNotEmpty);
    expect(progress.last.receivedBytes, payload.length);
    expect(progress.last.percent, 100);
    expect(progress.last.bytesPerSecond, greaterThanOrEqualTo(0));
    final file = File(result.filePath);
    expect(file.existsSync(), isTrue);
    expect(await file.readAsBytes(), payload);
    expect(result.bytes, payload.length);
  });

  test('downloadUpdate：第一个源 500 时自动换加速源，半截文件不残留', () async {
    final payload = utf8.encode('apk-from-accelerator');
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
    final url =
        'https://github.com/owner/repo/releases/download/v1.39.2/app.apk';
    await expectLater(
      UpdateService.downloadUpdate(
        update: updateFor(url),
        smartClient: SmartHttpClient(client: client),
        saveDir: tmp.path,
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
}
