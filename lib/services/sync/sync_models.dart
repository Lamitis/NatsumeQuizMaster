import 'dart:convert';

/// 局域网同步：信标与设备模型（纯 `dart:io`，无第三方网络插件）

/// 已发现的同步对端
class DiscoveredPeer {
  final String deviceId;
  final String deviceName;
  final String ip;
  final int port;
  final DateTime lastSeen;

  const DiscoveredPeer({
    required this.deviceId,
    required this.deviceName,
    required this.ip,
    required this.port,
    required this.lastSeen,
  });

  DiscoveredPeer copyWith({
    String? deviceName,
    String? ip,
    int? port,
    DateTime? lastSeen,
  }) {
    return DiscoveredPeer(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveredPeer && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// 同名题库冲突。
///
/// 同名（uid 不同、名字相同）的题库既不能直接覆盖，也不能直接忽略：
/// 内容一样就跳过，不一样则挂起冲突，由用户选择「覆盖」或
/// 「增添（只补对方多出来的部分）」。
///
/// 因此导入时遇到同名（uid 不同、名字相同）题库先比对内容指纹：
/// - 完全一致 → 直接跳过，不动本机数据；
/// - 不一致 → 生成一条冲突挂起，**本批不合并该题库及其题目**，
///   等用户在首页决定「覆盖」还是「增添」。
///
/// 冲突里带着对端该题库的原始数据（题库行 + 题目 + 配图），
/// 所以用户决策时不需要重新联网——这也是可以只放内存的原因。
class SyncBankConflict {
  const SyncBankConflict({
    required this.name,
    required this.peerBankUid,
    required this.peerBank,
    required this.peerQuestions,
    required this.peerImages,
    required this.localBankId,
    required this.localCount,
    required this.peerCount,
    required this.additionCount,
    required this.peerDeviceName,
  });

  /// 题库名（两端同名，这才叫冲突）
  final String name;

  /// 对端该题库的 uid
  final String peerBankUid;

  /// 对端题库行原始数据（覆盖时整行替换用）
  final Map<String, dynamic> peerBank;

  /// 对端题目原始数据
  final List<Map<String, dynamic>> peerQuestions;

  /// 对端题目配图（随题目一起搬）
  final List<Map<String, dynamic>> peerImages;

  /// 本机同名题库的本地 id
  final int localBankId;

  /// 本机题目数 / 对端题目数
  final int localCount;
  final int peerCount;

  /// 选「增添」时能补进来的题数（对端有、本机没有的）
  final int additionCount;

  /// 对端设备名（提示里给用户看「这是谁的题库」）
  final String peerDeviceName;

  /// 给用户看的一句话摘要
  String get summary =>
      '本机 $localCount 题 / 对端 $peerCount 题，其中对端多出 $additionCount 题';
}

/// 配对请求（双向握手载荷）。
///
/// 真机反馈：设备 A 输入 B 的识别码后，A 显示「已配对」，B 上点「立即同步」
/// 却提示「必须输入对端识别码才行」——配对只有单向：A 验证了 B，B 根本不知道
/// A 的存在。现在 A 核实通过后会把这份载荷 `POST /sync/pair` 给 B：
/// - 请求头携带 `X-Sync-Code: <B 的码>`：证明 A 确实知道 B 的识别码（B 侧门禁照旧）；
/// - 请求体里的 [code] 是 **A 自己的设备码**，B 收下后就有了回连 A 的凭据，
///   双方状态同时进入「已配对」。
class SyncPairRequest {
  const SyncPairRequest({
    required this.deviceId,
    required this.deviceName,
    required this.code,
    required this.port,
    this.address = '',
  });

  /// 对端设备 id（跨端唯一，用于日志与去重）
  final String deviceId;

  /// 对端设备名（为空时 UI 回落成地址）
  final String deviceName;

  /// 对端设备码——本机之后拿它作为 `X-Sync-Code` 向对端发请求
  final String code;

  /// 对端同步服务端口
  final int port;

  /// 对端来源地址（服务端从 `connectionInfo` 取，不信请求体里自报的 IP）
  final String address;

  bool get valid =>
      deviceId.isNotEmpty && code.isNotEmpty && address.isNotEmpty && port > 0;

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'device_name': deviceName,
        'code': code,
        'port': port,
      };

  /// 解析请求体；非法（缺字段 / 字段类型不对）返回 null
  static SyncPairRequest? parse(Object? raw, {required String address}) {
    if (raw is! Map) return null;
    final map = raw.map((k, v) => MapEntry(k.toString(), v));
    final deviceId = (map['device_id'] ?? '').toString().trim();
    final code = (map['code'] ?? '').toString().trim();
    final port = (map['port'] as num?)?.toInt() ?? 0;
    final name = (map['device_name'] ?? '').toString().trim();
    if (deviceId.isEmpty || code.isEmpty) return null;
    if (port <= 0 || port > 65535) return null;
    return SyncPairRequest(
      deviceId: deviceId,
      deviceName: name,
      code: code,
      port: port,
      address: address,
    );
  }

  @override
  String toString() => 'SyncPairRequest($deviceName / $deviceId @ $address:$port)';
}

class SyncBeacon {
  /// 协议魔数：过滤局域网内其他应用的 UDP 包
  static const String appTag = 'natsume_sync';
  static const int protocolVersion = 1;

  final String deviceId;
  final String deviceName;
  final int port;

  const SyncBeacon({
    required this.deviceId,
    required this.deviceName,
    required this.port,
  });

  String encode() => jsonEncode({
        'app': appTag,
        'v': protocolVersion,
        'device_id': deviceId,
        'device_name': deviceName,
        'port': port,
      });

  /// 解码信标；非法/他应用数据返回 null
  static SyncBeacon? decode(String raw) {
    try {
      final dynamic parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return null;
      if (parsed['app'] != appTag) return null;
      final deviceId = parsed['device_id'];
      final port = parsed['port'];
      if (deviceId is! String || deviceId.isEmpty) return null;
      if (port is! int || port <= 0) return null;
      final name = parsed['device_name'];
      return SyncBeacon(
        deviceId: deviceId,
        deviceName: name is String ? name : '',
        port: port,
      );
    } catch (_) {
      return null;
    }
  }
}
