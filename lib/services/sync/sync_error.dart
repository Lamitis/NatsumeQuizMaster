import 'dart:async';
import 'dart:io';

/// 同步业务错误码：底层捕获异常后必须返回**明确的业务错误**，而不是把原始异常抛给界面。
///
/// 未配对时点「立即同步」，界面转圈 30 秒后弹「时间溢出异常」——
/// 用户看到的是 `TimeoutException after 0:00:30` 这类**实现细节**，既不知道
/// 为什么失败，也不知道该做什么。根因是「未配对」这件事被交给了底层超时去发现。
///
/// 现在所有失败路径都收敛成 [SyncException]：一个**业务码 + 中文说明**，
/// UI 直接展示 [SyncException.message]，不再把 `TimeoutException` 泄漏给用户。
enum SyncErrorCode {
  /// 未完成双向配对（本机没拿到对端确认）：**不该发请求**，UI 层先拦
  notPaired,

  /// 识别码不被对端接受（403）／对端拒绝配对
  unauthorized,

  /// 握手、交换任一环节超时（含看门狗触发）
  timeout,

  /// 用户点了「取消同步」
  cancelled,

  /// 连不上对端（SocketException / 连接被拒 / 对端没开应用）
  peerUnreachable,

  /// 快照超过 64MB 单次上限
  payloadTooLarge,

  /// 对端快照格式非法（协议不兼容 / 包被截断）
  badSnapshot,

  /// 对端正在同步（HTTP 409）：同时双向全量互推会互相拖死，直接让后来者稍后重试
  busy,

  /// 数据库侧异常（合并失败 / 锁等待超时）
  database,

  /// 其他未归类失败
  unknown,
}

extension SyncErrorCodeInfo on SyncErrorCode {
  /// 对应的 HTTP 状态码（服务端错误响应用它）
  int get httpStatus => switch (this) {
        SyncErrorCode.notPaired => 403,
        SyncErrorCode.unauthorized => 403,
        SyncErrorCode.timeout => 504,
        SyncErrorCode.cancelled => 499,
        SyncErrorCode.peerUnreachable => 502,
        SyncErrorCode.payloadTooLarge => 413,
        SyncErrorCode.badSnapshot => 400,
        SyncErrorCode.busy => 409,
        SyncErrorCode.database => 500,
        SyncErrorCode.unknown => 500,
      };

  /// 机器可读的短名（写进响应体的 `code` 字段）
  String get wireName => switch (this) {
        SyncErrorCode.notPaired => 'not_paired',
        SyncErrorCode.unauthorized => 'unauthorized',
        SyncErrorCode.timeout => 'timeout',
        SyncErrorCode.cancelled => 'cancelled',
        SyncErrorCode.peerUnreachable => 'peer_unreachable',
        SyncErrorCode.payloadTooLarge => 'payload_too_large',
        SyncErrorCode.badSnapshot => 'bad_snapshot',
        SyncErrorCode.busy => 'busy',
        SyncErrorCode.database => 'database',
        SyncErrorCode.unknown => 'unknown',
      };

  /// 从响应体里的 `code` 字段还原
  static SyncErrorCode fromWire(String? wire) => switch (wire) {
        'not_paired' => SyncErrorCode.notPaired,
        'unauthorized' => SyncErrorCode.unauthorized,
        'timeout' => SyncErrorCode.timeout,
        'cancelled' => SyncErrorCode.cancelled,
        'peer_unreachable' => SyncErrorCode.peerUnreachable,
        'payload_too_large' => SyncErrorCode.payloadTooLarge,
        'bad_snapshot' => SyncErrorCode.badSnapshot,
        'busy' => SyncErrorCode.busy,
        'database' => SyncErrorCode.database,
        _ => SyncErrorCode.unknown,
      };

  /// 由 HTTP 状态码推业务码（响应体没有 `code` 时用）
  static SyncErrorCode fromHttpStatus(int status) => switch (status) {
        400 => SyncErrorCode.badSnapshot,
        403 => SyncErrorCode.unauthorized,
        409 => SyncErrorCode.busy,
        413 => SyncErrorCode.payloadTooLarge,
        499 => SyncErrorCode.cancelled,
        502 || 503 => SyncErrorCode.peerUnreachable,
        504 => SyncErrorCode.timeout,
        _ => SyncErrorCode.unknown,
      };
}

/// 同步业务异常。
///
/// 约定：**引擎对外只抛这个**（或把它写进 `statusMessage`），
/// 不把 `TimeoutException` / `SocketException` 直接甩给界面。
class SyncException implements Exception {
  const SyncException(this.code, this.message, {this.statusCode, this.cause});

  /// 业务码
  final SyncErrorCode code;

  /// 给用户看的中文说明（UI 直接展示）
  final String message;

  /// 触发的 HTTP 状态码（本地错误为空）
  final int? statusCode;

  /// 原始异常（只进日志，不给用户看）
  final Object? cause;

  bool get isCancelled => code == SyncErrorCode.cancelled;
  bool get isTimeout =>
      code == SyncErrorCode.timeout || code == SyncErrorCode.busy;

  /// 服务端响应 → 业务异常
  static SyncException fromResponse(int status, {String? body}) {
    final code = SyncErrorCodeInfo.fromHttpStatus(status);
    final hint = _hintOfBody(body);
    final text = switch (code) {
      SyncErrorCode.unauthorized => '识别码不匹配或已失效，对端拒绝了本次请求',
      SyncErrorCode.busy => '对端正在同步（HTTP 409）：请等它跑完再重试，不要两边同时点',
      SyncErrorCode.cancelled => '对端已中止本次同步',
      SyncErrorCode.timeout => '对端处理超时（HTTP 504）：数据量大或数据库繁忙，已中止本次同步',
      SyncErrorCode.payloadTooLarge => '同步数据超过 64MB 上限，请减少同步范围（只同步题库）',
      SyncErrorCode.badSnapshot => '对端快照格式非法（HTTP 400）：两端版本可能不一致',
      SyncErrorCode.peerUnreachable => '连不上对端（HTTP $status）：请确认对端应用在前台且防火墙已放行',
      _ => '对端返回 HTTP $status',
    };
    return SyncException(
      code,
      hint == null ? text : '$text（$hint）',
      statusCode: status,
      cause: body,
    );
  }

  /// 任意异常 → 业务异常（**「时间溢出」的收口点**）
  static SyncException wrap(Object error, {String action = '同步'}) {
    if (error is SyncException) return error;
    if (error is TimeoutException) {
      return SyncException(
        SyncErrorCode.timeout,
        '$action超时：对端在限定时间内没有响应'
        '（不是数据坏了，多半是对端卡住或网络不通）',
        cause: error,
      );
    }
    if (error is SocketException) {
      return SyncException(
        SyncErrorCode.peerUnreachable,
        '连不上对端：${error.osError?.message ?? '网络不可达'}'
        '（请确认对端应用在前台、两端同一 Wi-Fi、防火墙已放行 TCP 51630-51632）',
        cause: error,
      );
    }
    if (error is HttpException) {
      return SyncException(
        SyncErrorCode.peerUnreachable,
        '网络连接被中断：${error.message}',
        cause: error,
      );
    }
    final text = '$error';
    // http 包在连接被关闭时抛 ClientException（取消、对端崩、超时都会走这条）
    if (text.contains('ClientException') ||
        text.contains('Connection closed') ||
        text.contains('SocketException')) {
      return SyncException(
        SyncErrorCode.peerUnreachable,
        '连接中断：对端关闭了连接或网络不通（已中止本次$action）',
        cause: error,
      );
    }
    if (text.contains('DatabaseException') ||
        text.contains('database is locked') ||
        text.contains('SQLite')) {
      return SyncException(
        SyncErrorCode.database,
        '数据库繁忙或合并失败：已回滚本次$action，数据不会写坏',
        cause: error,
      );
    }
    return SyncException(
      SyncErrorCode.unknown,
      '$action失败：${text.length > 80 ? '${text.substring(0, 80)}…' : text}',
      cause: error,
    );
  }

  /// 从响应体里捞 `hint` / `error` 作为附加说明（只取短串）
  static String? _hintOfBody(String? body) {
    if (body == null || body.isEmpty) return null;
    final trimmed = body.trim();
    if (trimmed.length > 120 || trimmed.startsWith('<')) return null;
    return trimmed;
  }

  @override
  String toString() => 'SyncException(${code.wireName}): $message';
}
