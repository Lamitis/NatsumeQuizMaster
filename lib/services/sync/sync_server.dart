import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../debug_log_service.dart';
import '../device_service.dart';
import 'sync_error.dart';
import 'sync_models.dart';

/// 局域网同步服务端：本端起 `dart:io` HttpServer，暴露同步接口。
///
/// 接口（仅局域网内明文，无云端）：
/// - `GET  /sync/info`     → 本机设备信息（连通性探测 / 配对握手）
/// - `POST /sync/exchange` → 接收对端快照并合并入库，响应体返回本机快照，
///   对端收到后同样合并——一次请求完成双向同步
/// - `POST /sync/pair`     → **双向握手**：对端出示本机识别码，
///   并把「自己的识别码」交过来，双方同时进入「已配对」
/// - `POST /sync/cancel`   → 对端中止同步：本机立即停止生成快照并复位状态
///
/// 识别码门禁（避免把数据同步到不想同步的设备）：
/// 四个接口都要求请求头携带 `X-Sync-Code`，由注入的 [verifyCode] 校验
/// （设备长码或未过期的 6 位临时码，见 SyncCode）。不匹配一律 403。
/// **未注入校验器时默认拒绝**——避免调用方忘了接线就变成不设防。
///
/// 「同步无限转圈 / 十几分钟走不完」的服务端侧修复：
/// - 单次交换整体超时 [exchangeTimeout]（合并或生成快照卡住时回 504，
///   绝不让客户端一直等）；
/// - 同一时刻只处理一次交换（并发时回 409 `busy`）——两端同时互推全量
///   会互相拖死，明确让后来者稍后重试比一起卡住好；
/// - 所有错误都带上业务码（`code` 字段），客户端据此给出中文提示。
class SyncServer {
  /// 同步服务端口（被占用时依次尝试备用端口）
  static const List<int> candidatePorts = [51630, 51631, 51632];
  static const int maxBodyBytes = 64 * 1024 * 1024; // 64MB 上限（局域网全量快照）

  /// 识别码请求头
  static const String codeHeader = 'x-sync-code';

  /// 同步范围请求头：`full`（默认，整库）/ `banks`（仅题库，分享场景）
  static const String scopeHeader = 'x-sync-scope';

  /// 增量游标请求头（ISO8601）：请求方「我已经有到这个时刻的数据」，
  /// 服务端只回这个时刻之后的变更。缺省 = 全量（老客户端行为不变）。
  static const String sinceHeader = 'x-sync-since';

  /// 单次交换（合并 + 生成快照 + 写响应）的整体超时
  static const Duration exchangeTimeout = Duration(seconds: 120);

  /// 并发交换时的等待上限：等对端这一轮跑完再决定 409，而不是立刻拒绝
  static const Duration _busyWait = Duration(seconds: 10);

  HttpServer? _server;

  /// 对端推送的快照合并回调（引擎注入：SyncRepository.importSnapshot）
  Future<void> Function(Map<String, dynamic> snapshot)? onSnapshotReceived;

  /// 响应给对端的本机快照回调（引擎注入：SyncRepository.exportSnapshot）
  Future<Map<String, dynamic>> Function({required bool banksOnly})?
      buildSnapshot;

  /// 带游标的增量快照回调。未注入时退回 [buildSnapshot]（全量）——
  /// 这样单测里的老式 `snapshot:` 写法不受影响。
  Future<Map<String, dynamic>> Function(
      {required bool banksOnly, String? since})? buildIncrementalSnapshot;

  /// 收到对端配对请求（双向握手）。返回 true = 接受并已记录该对端。
  Future<bool> Function(SyncPairRequest request)? onPairRequest;

  /// 对端主动中止同步（引擎注入：把 UI 状态复位）
  void Function()? onCancel;

  /// 识别码校验器（引擎注入：presented 能否通过本机校验）。
  /// 为 null 时**拒绝所有请求**（默认安全，杜绝漏接线）。
  bool Function(String presented)? verifyCode;

  /// 是否有交换在进行中（诊断用）
  bool _exchanging = false;

  /// 对端已请求中止本次交换
  bool _cancelRequested = false;

  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  /// 当前是否正在处理一次交换（「网络诊断」展示用）
  bool get exchanging => _exchanging;

  Future<void> start({
    required Future<void> Function(Map<String, dynamic>) onReceived,
    required Future<Map<String, dynamic>> Function({required bool banksOnly})
        snapshot,
  }) async {
    if (running) return;
    onSnapshotReceived = onReceived;
    buildSnapshot = snapshot;

    HttpServer? server;
    for (final p in candidatePorts) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        break;
      } on SocketException {
        server = null;
      }
    }
    // 固定端口全被占用时退化为系统分配（信标携带实际端口，不影响发现）
    server ??= await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      // 识别码门禁：四个接口都要过（探测接口也不该对陌生设备开口）
      final presented = request.headers.value(codeHeader) ?? '';
      final verifier = verifyCode;
      if (verifier == null || !verifier(presented)) {
        await _respondError(request, SyncErrorCode.unauthorized,
            hint: '请求需要携带 X-Sync-Code（本机设备码或未过期的 6 位临时码）',
            message: 'sync code required');
        return;
      }

      final path = request.uri.path;
      if (path == '/sync/info' && request.method == 'GET') {
        await _respondJson(request, 200, {
          'device_id': await DeviceService.instance.deviceId,
          'device_name': await DeviceService.instance.deviceName,
          // 对端可据此直接握手/回连，省一次发现
          'port': port,
        });
        return;
      }
      if (path == '/sync/pair' && request.method == 'POST') {
        await _handlePair(request);
        return;
      }
      if (path == '/sync/cancel' && request.method == 'POST') {
        await _handleCancel(request);
        return;
      }
      if (path == '/sync/exchange' && request.method == 'POST') {
        await _handleExchange(request);
        return;
      }
      await _respondError(request, SyncErrorCode.unknown,
          message: 'not found', status: 404);
    } catch (e) {
      DebugLogService.instance.log('SYNC', '同步服务端处理异常: $e');
      try {
        await _respondError(request, SyncErrorCode.unknown, message: '$e');
      } catch (_) {}
    }
  }

  /// 双向握手：对端出示本机识别码（门禁已过），并把自己的识别码交过来。
  ///
  /// 这一步是「A 显示已配对、B 却仍要求输入识别码」的根治点：B 收到请求后
  /// 立刻拥有回连 A 的凭据，双方同时显示「已配对」。
  Future<void> _handlePair(HttpRequest request) async {
    final bytes = await _readBodyLimited(request);
    if (bytes == null) {
      await _respondError(request, SyncErrorCode.payloadTooLarge,
          message: 'pair body too large');
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      await _respondError(request, SyncErrorCode.badSnapshot,
          message: 'bad pair request');
      return;
    }
    final address = request.connectionInfo?.remoteAddress.address ?? '';
    final req = SyncPairRequest.parse(decoded, address: address);
    if (req == null || !req.valid) {
      await _respondError(request, SyncErrorCode.badSnapshot,
          hint: '需要 device_id / code / port 三个字段',
          message: 'bad pair request');
      return;
    }
    final selfId = await DeviceService.instance.deviceId;
    if (req.deviceId == selfId) {
      // 自己配对给自己（同一台设备的两条路径）：不算错，直接返回
      await _respondJson(request, 200, {
        'ok': true,
        'self': true,
        'device_id': selfId,
      });
      return;
    }
    final handler = onPairRequest;
    if (handler == null) {
      await _respondError(request, SyncErrorCode.unknown,
          hint: '本端未启用配对服务',
          message: 'pairing not supported',
          status: 503);
      return;
    }
    final accepted = await handler(req);
    if (!accepted) {
      await _respondError(request, SyncErrorCode.unauthorized,
          message: 'pairing rejected');
      return;
    }
    DebugLogService.instance
        .log('SYNC', '已接受配对请求：${req.deviceName}@${req.address}:${req.port}');
    await _respondJson(request, 200, {
      'ok': true,
      'device_id': selfId,
      'device_name': await DeviceService.instance.deviceName,
    });
  }

  /// 对端中止同步：立刻置取消标记（合并结束后不再生成/回传快照）。
  Future<void> _handleCancel(HttpRequest request) async {
    _cancelRequested = true;
    DebugLogService.instance.log('SYNC', '收到对端的中止请求');
    onCancel?.call();
    await _respondJson(request, 200, {'ok': true, 'cancelled': true});
  }

  /// 交换：**整体加超时 + 并发保护**（无限转圈的两个服务端成因）。
  Future<void> _handleExchange(HttpRequest request) async {
    // 对端可能正在处理另一次交换（两端同时自动同步是常见情形）：
    // 先等一小会儿再决定，直接 409 会把「双方都想同步」变成「双方都失败」。
    final waitUntil = DateTime.now().add(_busyWait);
    while (_exchanging && DateTime.now().isBefore(waitUntil)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_exchanging) {
      await _respondError(request, SyncErrorCode.busy,
          hint: '对端正在同步，请等它结束后重试（不要两端同时点「立即同步」）',
          message: 'busy');
      return;
    }
    _exchanging = true;
    _cancelRequested = false;
    final sw = Stopwatch()..start();
    try {
      await _handleExchangeInner(request).timeout(
        exchangeTimeout,
        onTimeout: () async {
          // 交换整体超时：必须**先把响应写完**，否则客户端会一直等（旧行为）
          DebugLogService.instance.log(
              'SYNC', '交换处理超时（${exchangeTimeout.inSeconds}s），已回 504');
          await _respondError(request, SyncErrorCode.timeout,
              hint: '对端合并或生成快照超时，已中止本次交换',
              message: 'exchange timeout');
        },
      );
    } finally {
      DebugLogService.instance
          .log('SYNC', '交换处理结束，耗时 ${sw.elapsedMilliseconds}ms');
      debugPrint('[SYNC] exchange handled in ${sw.elapsedMilliseconds}ms');
      _exchanging = false;
      _cancelRequested = false;
    }
  }

  Future<void> _handleExchangeInner(HttpRequest request) async {
    final bytes = await _readBodyLimited(request);
    if (bytes == null) {
      await _respondError(request, SyncErrorCode.payloadTooLarge,
          message: 'body too large');
      return;
    }
    Map<String, dynamic> peerSnapshot;
    try {
      final dynamic parsed = jsonDecode(utf8.decode(bytes));
      if (parsed is! Map<String, dynamic>) {
        await _respondError(request, SyncErrorCode.badSnapshot,
            message: 'bad snapshot');
        return;
      }
      peerSnapshot = parsed;
    } catch (_) {
      await _respondError(request, SyncErrorCode.badSnapshot,
          message: 'bad snapshot');
      return;
    }

    // 先合并对端数据，再返回本机快照——对端拿到的快照已含本机最新状态
    final receiver = onSnapshotReceived;
    if (receiver != null) {
      final mergeWatch = Stopwatch()..start();
      try {
        await receiver(peerSnapshot);
      } catch (e) {
        // 合并失败必须回明确的业务错误，而不是让客户端等到超时
        DebugLogService.instance.log('SYNC', '合并对端快照失败: $e');
        await _respondError(request, SyncErrorCode.database,
            hint: '对端数据合并失败，已回滚本次合并',
            message: '$e');
        return;
      }
      DebugLogService.instance
          .log('SYNC', '合并对端快照完成，耗时 ${mergeWatch.elapsedMilliseconds}ms');
      debugPrint('[SYNC] merge peer snapshot ${mergeWatch.elapsedMilliseconds}ms');
    }

    if (_cancelRequested) {
      // 对端已中止：不要再生成/回传本机快照（那会白跑一遍全库导出）
      await _respondError(request, SyncErrorCode.cancelled,
          message: 'cancelled by peer');
      return;
    }

    // 同步范围：请求方声明 banks 时只回题库（用户之间分享题库的场景）
    final banksOnly = request.headers.value(scopeHeader) == 'banks';
    // 增量游标：请求方声明「已有到 since 的数据」时只回增量
    final sinceRaw = request.headers.value(sinceHeader);
    final since = (sinceRaw == null || sinceRaw.isEmpty)
        ? null
        : DateTime.tryParse(sinceRaw);
    // 回调签名用 ISO 字符串（服务端不替引擎做时间解析，保持适配层薄）
    final sinceParam = since?.toIso8601String();
    final buildWatch = Stopwatch()..start();
    Map<String, dynamic> snapshot;
    final incremental = buildIncrementalSnapshot;
    try {
      if (incremental != null) {
        snapshot = await incremental(banksOnly: banksOnly, since: sinceParam);
      } else if (buildSnapshot != null) {
        snapshot = await buildSnapshot!(banksOnly: banksOnly);
      } else {
        snapshot = <String, dynamic>{};
      }
    } catch (e) {
      DebugLogService.instance.log('SYNC', '生成本机快照失败: $e');
      await _respondError(request, SyncErrorCode.database,
          hint: '本机快照生成失败，未能把数据回传给对端',
          message: '$e');
      return;
    }
    final sinceText =
        since == null ? '全量' : '增量自 ${since.toIso8601String()}';
    DebugLogService.instance.log('SYNC',
        '生成回传快照完成，耗时 ${buildWatch.elapsedMilliseconds}ms（$sinceText）');
    debugPrint('[SYNC] build snapshot ${buildWatch.elapsedMilliseconds}ms '
        'incremental=${since != null}');

    await _respondJson(request, 200, snapshot);
  }

  Future<List<int>?> _readBodyLimited(HttpRequest request) async {
    final sink = BytesBuilder(copy: false);
    await for (final chunk in request) {
      sink.add(chunk);
      if (sink.length > maxBodyBytes) return null;
    }
    return sink.takeBytes();
  }

  Future<void> _respondJson(
      HttpRequest request, int status, Map<String, dynamic> body) async {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    } catch (e) {
      // 超时/取消后响应可能已被写过或连接已断：只记日志，不再抛出
      // （抛出会污染调用栈，看起来像另一个 bug）
      debugPrint('[SYNC] respond failed: $e');
    }
  }

  /// 统一错误响应：`code` 给客户端做业务判定，`error` / `hint` 给人看
  Future<void> _respondError(
    HttpRequest request,
    SyncErrorCode code, {
    required String message,
    String? hint,
    int? status,
  }) {
    return _respondJson(request, status ?? code.httpStatus, {
      'ok': false,
      'code': code.wireName,
      'error': message,
      if (hint != null) 'hint': hint,
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
