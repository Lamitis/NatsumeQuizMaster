import 'dart:io';

import 'sync_backend.dart';
import 'syncthing_client.dart';

/// Syncthing 同步后端（v13 · 参考 syncthing）。
///
/// 把NatsumeQuizMaster的题库/知识库落到一个 Syncthing 共享目录，由 Syncthing 负责跨设备
/// 传输；本后端只做「控制 Syncthing 实例 + 扫码配对 + 目录定位」。
///
/// 实例拉起是原生构建步骤（见 `docs/同步说明.md`）：
///   · 桌面端：捆绑/下载 `syncthing(.exe)` 子进程，或附着已装实例；
///   · Android 端：经 gomobile 编译 `lib/syncthing` 成 `.aar`，在进程内跑。
/// 两种方式暴露的都是同一个 REST 接口 + 共享目录，本后端无需区分。
class SyncthingBackend implements SyncBackend {
  final SyncthingClient client;
  final String folderId;
  final String label;
  final Directory dataDirectory;

  SyncthingBackend({
    required this.client,
    required this.folderId,
    required this.label,
    required this.dataDirectory,
  });

  String? _cachedDeviceId;

  Future<String> deviceId() async =>
      _cachedDeviceId ??= await client.myDeviceId();

  /// 生成本机配对载荷（供生成二维码给对方扫）。
  Future<SyncthingPairPayload> buildPairPayload() async {
    return SyncthingPairPayload(
      deviceId: await deviceId(),
      apiKey: client.apiKey,
      folderId: folderId,
    );
  }

  @override
  Future<bool> isReady() async {
    if (!dataDirectory.existsSync()) {
      dataDirectory.createSync(recursive: true);
    }
    return client.ping();
  }

  @override
  Future<String> dataDir() async => dataDirectory.path;

  @override
  Future<void> pair(SyncthingPairPayload pair) async {
    final config = await client.getConfig();
    client.addDevice(config, pair.deviceId, 'NatsumeQuizMaster设备');
    client.addFolder(config, folderId, label, dataDirectory.path,
        [pair.deviceId]);
    // 也把对方目录加进来（若对方目录 id 不同，则按对方 id 共享，保证两端互通）
    if (pair.folderId.isNotEmpty && pair.folderId != folderId) {
      client.addFolder(config, pair.folderId, label, dataDirectory.path,
          [pair.deviceId]);
    }
    await client.setConfig(config);
  }

  @override
  Future<void> sync() async {
    // Syncthing 是持续同步：这里只做一次状态探测，确认目录已登记。
    await client.folderStatus(folderId);
  }

  @override
  void dispose() {
    client.dispose();
  }
}
