import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/device_service.dart';
import 'package:natsume_quiz_master/services/sync/sync_error.dart';
import 'package:natsume_quiz_master/services/sync/sync_models.dart';
import 'package:natsume_quiz_master/services/sync/sync_repository.dart';
import 'package:natsume_quiz_master/services/sync/sync_server.dart';

/// 2026-10-30 真机三问题的回归测试：
/// 1. 未配对同步不再靠底层超时（业务错误码 + 双向握手接口）；
/// 2. 同步不会无限转圈（服务端超时/忙/取消都有明确响应）；
/// 3. 「几十道题同步十几分钟」的两个根因——嵌套 `db.batch` 死锁与全量重传。
void main() {
  group('SyncException：异常 → 业务错误（不再泄漏 TimeoutException）', () {
    test('TimeoutException 翻成 timeout', () {
      final ex = SyncException.wrap(TimeoutException('boom'));
      expect(ex.code, SyncErrorCode.timeout);
      expect(ex.message, contains('超时'));
      expect(ex.message.contains('TimeoutException'), isFalse,
          reason: '用户不该看到「时间溢出」这类实现细节');
    });

    test('SocketException 翻成 peerUnreachable 并给出排查建议', () {
      final ex = SyncException.wrap(
          const SocketException('Connection refused', osError: OSError()));
      expect(ex.code, SyncErrorCode.peerUnreachable);
      expect(ex.message, contains('防火墙'));
    });

    test('HTTP 状态码映射：403 / 409 / 413 / 504', () {
      expect(SyncException.fromResponse(403).code, SyncErrorCode.unauthorized);
      expect(SyncException.fromResponse(409).code, SyncErrorCode.busy);
      expect(SyncException.fromResponse(413).code, SyncErrorCode.payloadTooLarge);
      expect(SyncException.fromResponse(504).code, SyncErrorCode.timeout);
      expect(SyncException.fromResponse(403).statusCode, 403);
    });

    test('wrap 对 SyncException 幂等（不重复包装）', () {
      const origin = SyncException(SyncErrorCode.cancelled, '已取消');
      expect(identical(SyncException.wrap(origin), origin), isTrue);
    });

    test('业务码 → HTTP 状态码（服务端错误响应用）', () {
      expect(SyncErrorCode.unauthorized.httpStatus, 403);
      expect(SyncErrorCode.busy.httpStatus, 409);
      expect(SyncErrorCode.timeout.httpStatus, 504);
      expect(SyncErrorCode.cancelled.httpStatus, 499);
    });
  });

  group('SyncPairRequest（双向握手载荷）', () {
    test('正常解析，地址以连接来源为准', () {
      final req = SyncPairRequest.parse(
        {
          'device_id': 'dev-a',
          'device_name': '手机',
          'code': 'A-CODE',
          'port': 51630,
          // 自报 IP 不可信，必须被 connectionInfo 覆盖
          'address': '1.2.3.4',
        },
        address: '192.168.1.9',
      );
      expect(req, isNotNull);
      expect(req!.address, '192.168.1.9');
      expect(req.valid, isTrue);
    });

    test('缺字段 / 端口非法一律判非法', () {
      expect(SyncPairRequest.parse({'device_id': 'a'}, address: '1.1.1.1'),
          isNull);
      expect(
          SyncPairRequest.parse(
              {'device_id': 'a', 'code': 'c', 'port': 0}, address: '1.1.1.1'),
          isNull);
      expect(SyncPairRequest.parse('not a map', address: '1.1.1.1'), isNull);
    });
  });
  group('SyncServer：配对 / 取消 / 增量', () {
    const code = 'PEER-CODE-1234';

    Future<SyncServer> startServer({
      Future<bool> Function(SyncPairRequest)? onPair,
      void Function()? onCancel,
      Future<Map<String, dynamic>> Function(
              {required bool banksOnly, String? since})? incremental,
    }) async {
      final server = SyncServer();
      await server.start(
        onReceived: (snap) async {},
        snapshot: ({required bool banksOnly}) async =>
            {'device_id': 'self', 'scope': 'full'},
      );
      server.verifyCode = (presented) => presented == code;
      if (onPair != null) server.onPairRequest = onPair;
      if (onCancel != null) server.onCancel = onCancel;
      if (incremental != null) server.buildIncrementalSnapshot = incremental;
      return server;
    }

    test('POST /sync/pair：门禁通过 → 回调 → 200；不带码 403', () async {
      SyncPairRequest? seen;
      final server = await startServer(onPair: (req) async {
        seen = req;
        return true;
      });
      final client = http.Client();
      try {
        final uri = Uri.parse('http://127.0.0.1:${server.port}/sync/pair');
        final ok = await client.post(uri, headers: {
          SyncServer.codeHeader: code,
          'Content-Type': 'application/json',
        }, body: jsonEncode({
          'device_id': 'dev-a',
          'device_name': '手机',
          'code': 'A-CODE',
          'port': 51630,
        }));
        expect(ok.statusCode, 200);
        expect(seen?.code, 'A-CODE');
        expect(seen?.deviceName, '手机');
        expect(seen?.address, isNotEmpty, reason: '地址应来自 connectionInfo');

        final denied = await client.post(uri, body: '{}');
        expect(denied.statusCode, 403, reason: '配对接口同样受识别码门禁保护');
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('POST /sync/pair：回调拒绝 → 403；载荷非法 → 400', () async {
      final server = await startServer(onPair: (req) async => false);
      final client = http.Client();
      try {
        final uri = Uri.parse('http://127.0.0.1:${server.port}/sync/pair');
        final rejected = await client.post(uri, headers: {
          SyncServer.codeHeader: code,
        }, body: jsonEncode({
          'device_id': 'dev-a',
          'code': 'A-CODE',
          'port': 51630,
        }));
        expect(rejected.statusCode, 403);

        final bad = await client
            .post(uri, headers: {SyncServer.codeHeader: code}, body: 'not-json');
        expect(bad.statusCode, 400);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('POST /sync/cancel：回调被触发，返回 200', () async {
      var cancelled = 0;
      final server = await startServer(onCancel: () => cancelled++);
      final client = http.Client();
      try {
        final resp = await client.post(
          Uri.parse('http://127.0.0.1:${server.port}/sync/cancel'),
          headers: {SyncServer.codeHeader: code},
        );
        expect(resp.statusCode, 200);
        expect(cancelled, 1);
      } finally {
        client.close();
        await server.stop();
      }
    });

    test('POST /sync/exchange：x-sync-since 原样传给增量回调', () async {
      String? gotSince;
      var calls = 0;
      final server = await startServer(
        incremental: ({required bool banksOnly, String? since}) async {
          calls++;
          gotSince = since;
          return {
            'device_id': 'self',
            'incremental': since != null,
            'exported_at': '2026-10-30T12:00:00.000',
          };
        },
      );
      final client = http.Client();
      try {
        final uri = Uri.parse('http://127.0.0.1:${server.port}/sync/exchange');
        final resp = await client.post(uri, headers: {
          SyncServer.codeHeader: code,
          SyncServer.sinceHeader: '2026-10-30T08:00:00.000',
        }, body: jsonEncode({'device_id': 'peer-x'}));
        expect(resp.statusCode, 200);
        expect(gotSince, '2026-10-30T08:00:00.000');
        final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
        expect(body['incremental'], isTrue);

        // 不带游标 = 全量（老客户端行为不变）
        await client.post(uri,
            headers: {SyncServer.codeHeader: code},
            body: jsonEncode({'device_id': 'peer-x'}));
        expect(calls, 2);
        expect(gotSince, isNull);
      } finally {
        client.close();
        await server.stop();
      }
    });
  });


  group('SyncRepository：增量导出 + 配图合并（不卡死）', () {
    late String dbPath;
    final repo = SyncRepository();

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await DatabaseService.instance.close();
      dbPath =
          '${Directory.systemTemp.path}/natsume_sync_inc_${DateTime.now().microsecondsSinceEpoch}.db';
      DatabaseService.overrideDbPath = dbPath;
      DeviceService.instance.overrideDeviceId('self-device');
      DeviceService.instance.overrideDeviceName('本机');
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    });

    /// 造一个题库 + 一道题 + 一张配图（配图是关键：旧实现在事务里调
    /// `db.batch()`，会把合并永久卡住）
    Future<int> seed({
      required String bankUid,
      required String name,
      required String stamp,
      bool withImage = true,
    }) async {
      final db = await DatabaseService.instance.database;
      final bankId = await db.insert('question_banks', {
        'uid': bankUid,
        'name': name,
        'file_source': 'seed.docx',
        'question_count': 1,
        'created_at': stamp,
        'updated_at': stamp,
      });
      final qId = await db.insert('questions', {
        'uid': '$bankUid-q0',
        'bank_id': bankId,
        'title': '$name-题一',
        'options': jsonEncode(['A', 'B']),
        'correct_answer': 'A',
        'question_type': 'single_choice',
        'source': 'real',
        'created_at': stamp,
        'updated_at': stamp,
      });
      if (withImage) {
        await db.insert('question_images', {
          'question_id': qId,
          'position': 0,
          'mime': 'image/png',
          'width': 1,
          'height': 1,
          'content': Uint8List.fromList([1, 2, 3, 4]),
        });
      }
      return bankId;
    }

    test('exportSnapshot(since:)：只带变更过的题目与配图，题库行全带', () async {
      await seed(
          bankUid: 'old-bank', name: '旧题库', stamp: '2026-09-01T00:00:00.000');
      await seed(
          bankUid: 'new-bank', name: '新题库', stamp: '2026-10-30T00:00:00.000');

      final snapshot = await repo.exportSnapshot(
        since: DateTime.parse('2026-10-29T00:00:00.000'),
      );

      expect(snapshot['incremental'], isTrue);
      expect(snapshot['exported_at'], isA<String>());
      expect((snapshot['questions'] as List), hasLength(1),
          reason: '只有 10-30 那道题是变更过的');
      expect((snapshot['questions'] as List).first['uid'], 'new-bank-q0');
      expect((snapshot['question_images'] as List), hasLength(1),
          reason: '未变更题目的配图不该再传一遍（这是几 MB 流量）');
      expect((snapshot['banks'] as List), hasLength(2),
          reason: '题库行要全带，否则对端无法把题目映射到本地题库');
    });

    test('exportSnapshot()：不传 since 仍是全量（老客户端行为不变）', () async {
      await seed(bankUid: 'b1', name: '题库一', stamp: '2026-09-01T00:00:00.000');
      await seed(bankUid: 'b2', name: '题库二', stamp: '2026-09-02T00:00:00.000');
      final snapshot = await repo.exportSnapshot();
      expect(snapshot['incremental'], isFalse);
      expect((snapshot['questions'] as List), hasLength(2));
      expect((snapshot['question_images'] as List), hasLength(2));
    });

    test('importSnapshot 带配图：事务内写完，不会卡死（旧实现会永久挂起）', () async {
      final snapshot = <String, dynamic>{
        'protocol': 1,
        'device_id': 'peer-device',
        'device_name': '平板',
        'exported_at': '2026-10-30T00:00:00.000',
        'banks': [
          {
            'uid': 'peer-bank',
            'name': '对端题库',
            'file_source': 'peer.docx',
            'question_count': 1,
            'created_at': '2026-10-30T00:00:00.000',
            'updated_at': '2026-10-30T00:00:00.000',
          }
        ],
        'questions': [
          {
            'uid': 'peer-bank-q0',
            'bank_uid': 'peer-bank',
            'title': '对端题一',
            'options': jsonEncode(['A', 'B']),
            'correct_answer': 'A',
            'question_type': 'single_choice',
            'created_at': '2026-10-30T00:00:00.000',
            'updated_at': '2026-10-30T00:00:00.000',
          }
        ],
        'question_images': [
          {
            'question_uid': 'peer-bank-q0',
            'position': 0,
            'mime': 'image/png',
            'width': 1,
            'height': 1,
            'content': base64Encode([9, 9, 9]),
          }
        ],
        'sessions': const [],
        'answer_records': const [],
        'error_book': const [],
        'annotations': const [],
        'plugins': const <String, dynamic>{},
      };

      final merged = await repo
          .importSnapshot(snapshot)
          .timeout(const Duration(seconds: 20));

      expect(merged, greaterThan(0));
      final db = await DatabaseService.instance.database;
      final images = await db.query('question_images');
      expect(images, hasLength(1), reason: '配图必须落库');
    });

    test('增量快照不做同名内容比对（避免部分题目造成假冲突）', () async {
      await seed(bankUid: 'local-x', name: '生理学', stamp: '2026-09-01T00:00:00.000');
      final conflicts = <SyncBankConflict>[];
      await repo.importSnapshot(
        {
          'device_id': 'peer-device',
          'incremental': true,
          'banks': [
            {
              'uid': 'peer-x',
              'name': '生理学',
              'updated_at': '2026-10-30T00:00:00.000',
            }
          ],
          'questions': const [],
          'question_images': const [],
          'sessions': const [],
          'answer_records': const [],
          'error_book': const [],
          'annotations': const [],
        },
        conflictSink: conflicts,
      );
      expect(conflicts, isEmpty,
          reason: '增量只带部分题目，拿它比指纹会把「3 题 vs 30 题」误判成内容不同');
    });
  });
}

