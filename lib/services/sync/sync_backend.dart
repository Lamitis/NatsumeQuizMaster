import 'dart:convert';

/// 跨端同步后端抽象（v13）。
///
/// 现有局域网同步（`SyncEngine`）与新增的 Syncthing 后端都实现同一接口，
/// 上层「扫码配对 → 交换题库/知识库 → 监听变更自动导入」不必关心底层是谁。
abstract class SyncBackend {
  /// 配对：让本机与 [pair] 描述的对方设备建立信任、共享数据目录。
  Future<void> pair(SyncthingPairPayload pair);

  /// 同步数据目录的路径（Syncthing 共享目录，或局域网同步的导出目录）。
  Future<String> dataDir();

  /// 触发一次即时交换/刷新。
  Future<void> sync();

  /// 是否就绪（后端已启动、可配对）。
  Future<bool> isReady();

  void dispose();
}

/// Syncthing 扫码配对载荷。
///
/// 二维码内容 = 本类的 JSON。对方扫码后，用 `deviceId` 添加设备、用
/// `folderId` 共享目录、用 `apiKey` 走 REST 控制自己的 Syncthing 实例。
class SyncthingPairPayload {
  final String deviceId;
  final String apiKey;
  final String folderId;
  final String? address; // 可选：`tcp://host:22000` 直连提示

  const SyncthingPairPayload({
    required this.deviceId,
    required this.apiKey,
    required this.folderId,
    this.address,
  });

  String toJson() => jsonEncode({
        'v': 1,
        'device_id': deviceId,
        'api_key': apiKey,
        'folder_id': folderId,
        if (address != null) 'address': address,
      });

  static SyncthingPairPayload? fromJson(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return null;
      return SyncthingPairPayload(
        deviceId: (d['device_id'] ?? '').toString(),
        apiKey: (d['api_key'] ?? '').toString(),
        folderId: (d['folder_id'] ?? '').toString(),
        address: d['address']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}
