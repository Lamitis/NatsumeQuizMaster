import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'lan_address.dart';
import 'sync_models.dart';

/// 发现通道的运行统计：用户看不到包，就永远查不出「为什么发现不了设备」。
///
/// 真机反馈（2026-10-30）暴露的正是这一点：socket 被静默打死、所有异常都被
/// `catch (_) {}` 吞掉，界面上只剩一句「未发现设备」，无从判断是「没发出」
/// 「没收到」还是「被防火墙挡了」。
class SyncDiscoveryStats {
  const SyncDiscoveryStats({
    required this.sent,
    required this.sendFailures,
    required this.received,
    required this.ignored,
    required this.lastSentAt,
    required this.lastReceivedAt,
    required this.lastError,
    required this.boundPort,
    required this.heals,
    required this.interfaces,
  });

  /// 成功发出的信标包数（广播 / 多播 / 单播扫描 / 应答 全部计入）
  final int sent;

  /// 发送失败次数（多为权限或网卡问题，见 [lastError]）
  final int sendFailures;

  /// 收到并识别为本应用的信标数
  final int received;

  /// 收到但不是本应用的包数（区分「没收到」与「收到了但解析不了」）
  final int ignored;

  final DateTime? lastSentAt;
  final DateTime? lastReceivedAt;

  /// 最近一次发送异常的一句话描述
  final String? lastError;

  /// 信标监听端口（0 = 没绑定成功）
  final int boundPort;

  /// socket 被系统关闭后自动重建的次数
  final int heals;

  /// 参与广播 / 扫描的网卡（“名字 (地址)”）
  final List<String> interfaces;

  bool get healthy => boundPort > 0;

  /// 一句话诊断（设置页「网络诊断」直接展示）
  String get summary {
    final parts = <String>['已发 $sent · 已收 $received'];
    if (sendFailures > 0) parts.add('发送失败 $sendFailures');
    if (heals > 0) parts.add('socket 重建 $heals');
    return parts.join(' · ');
  }
}


/// 局域网设备发现（纯 `dart:io` RawDatagramSocket）——三通道：
///
/// 1. 子网单播扫描（主力，最可靠）：周期扫描本机各网段的全部主机地址，
///    逐个单播信标。单播属于「出站流量」不受入站防火墙规则限制；对端收到后
///    单播应答自己的信标 → 双向发现互不依赖广播可达性。
/// 2. 多播（辅助）：加入固定多播组互发信标（dart:io 正式支持）。
/// 3. 广播（辅助）：受限广播 + 子网定向广播。
///    实测部分平台广播「发送不抛错但包不达」，故仅作为补充通道。
///
/// 维护「发现的设备」列表：按 device_id 去重、[peerTimeout] 未刷新剔除。
class SyncDiscovery {
  /// 信标端口（主 + 备；绑定用，收发都覆盖两个端口以兼容对端降级绑定）
  static const int primaryPort = 51620;
  static const int fallbackPort = 51621;

  /// 多播组与端口（固定；两端约定一致即可）
  static final InternetAddress multicastGroup = InternetAddress('239.192.93.93');
  static const int multicastPort = 51622;

  static const Duration beaconInterval = Duration(seconds: 3);
  static const Duration scanInterval = Duration(seconds: 6);
  static const Duration peerTimeout = Duration(seconds: 10);

  /// 收到信标后的应答节流：同一设备最近一次应答时间（防扫描风暴）
  final Map<String, DateTime> _lastReplyAt = {};
  static const Duration replyCooldown = Duration(seconds: 3);

  // ── 运行统计（只读，供设置页「网络诊断」展示）──
  int _sent = 0;
  int _sendFailures = 0;
  int _received = 0;
  int _ignored = 0;
  int _heals = 0;
  DateTime? _lastSentAt;
  DateTime? _lastReceivedAt;
  String? _lastError;
  bool _healing = false;
  List<String> _scanInterfaces = const [];
  List<LanInterface>? _ifaceCache;
  DateTime _ifaceCacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  RawDatagramSocket? _socket;
  RawDatagramSocket? _mcastSocket;
  StreamSubscription<RawSocketEvent>? _subscription;
  StreamSubscription<RawSocketEvent>? _mcastSubscription;
  Timer? _broadcastTimer;
  Timer? _scanTimer;
  Timer? _pruneTimer;
  bool _broadcasting = false;
  bool _scanning = false;
  final List<int> _boundPorts = [];
  String _selfDeviceId = '';

  final Map<String, DiscoveredPeer> _peers = {};

  /// 构造本机信标（引擎注入：携带最新的同步服务端口与设备名）
  Future<SyncBeacon> Function()? buildBeacon;

  /// 新设备首次被发现（引擎据此触发自动同步）
  void Function(DiscoveredPeer peer)? onPeerDiscovered;

  /// 设备列表增删变化（设置页状态刷新；lastSeen 刷新不触发）
  VoidCallbackLike? onPeersChanged;

  bool get running => _socket != null;
  bool get broadcasting => _broadcasting;

  /// 当前发现的对端（已剔除超时）
  List<DiscoveredPeer> get peers {
    _prunePeers(DateTime.now());
    return _peers.values.toList()
      ..sort((a, b) => a.deviceName.compareTo(b.deviceName));
  }

  /// 启动发现：绑定监听 + 多播组；[broadcast] 为 true 时开始周期
  /// 广播与子网扫描。监听始终开启（手动「立即同步」也依赖被发现列表）
  Future<void> start({
    required String deviceId,
    required Future<SyncBeacon> Function() beacon,
    bool broadcast = false,
  }) async {
    if (running) return;
    _selfDeviceId = deviceId;
    buildBeacon = beacon;

    final socket = await _bindBeaconSocket();
    if (socket == null) {
      throw const SocketException('局域网发现：无法绑定信标端口');
    }
    _socket = socket;
    _sent = 0;
    _sendFailures = 0;
    _received = 0;
    _ignored = 0;
    _heals = 0;
    _lastSentAt = null;
    _lastReceivedAt = null;
    _lastError = null;
    _subscription = socket.listen(_onSocketEvent, onError: (Object e) {
      _lastError = '接收异常：${_brief(e)}';
      if (_looksClosed(e)) unawaited(_healSocket());
    });

    // 多播通道（辅助）：绑定失败/加组失败降级跳过，不影响单播主力
    try {
      final ms = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, multicastPort,
          reuseAddress: true);
      ms.joinMulticast(multicastGroup);
      _mcastSocket = ms;
      _mcastSubscription = ms.listen(_onSocketEventMcast, onError: (_) {});
    } catch (_) {
      _mcastSocket = null;
    }

    _pruneTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _pruneAndNotify());

    await setBroadcasting(broadcast);
  }
  /// 绑定信标端口，并**立刻打开 SO_BROADCAST**。
  ///
  /// 这是 2026-10-30 真机「同 Wi-Fi 下永远发现不了设备」的直接根因：
  /// 未开启广播权限时，`dart:io` 向 `255.255.255.255` 发送会让系统异步报错并
  /// **销毁这个 UDP socket**——`send` 看起来成功、包其实没发出，之后所有
  /// send/receive 全部抛 `Socket has been closed`。旧实现在 bind 后从未设置
  /// `broadcastEnabled`，而 `_sendBeacon()` 又把 `255.255.255.255` 排在
  /// 目标列表第一位，于是服务启动后第一个信标周期就把自己打死：`running`
  /// 仍是 true、HTTP 服务也在，但发现通道彻底哑掉。
  ///
  /// 实测（Windows + Dart 3.x）：
  /// - 不设 `broadcastEnabled`：发 255.255.255.255 → socket 立即失效、收包 0；
  /// - 先设 `broadcastEnabled = true`：连续 21 次广播全部送达、socket 正常。
  Future<RawDatagramSocket?> _bindBeaconSocket() async {
    for (final port in [primaryPort, fallbackPort]) {
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
        );
        try {
          socket.broadcastEnabled = true;
        } catch (_) {
          // 个别平台/沙箱不允许改该选项；此时广播会失败，由单播扫描兜底，
          // 失败次数会记进 stats 供「网络诊断」显示
        }
        _boundPorts
          ..clear()
          ..add(port);
        return socket;
      } on SocketException {
        // 该端口不可用，继续尝试下一个
      }
    }
    return null;
  }

  /// 发送信标：所有调用点统一走这里，失败计数 + socket 自愈
  void _safeSend(RawDatagramSocket socket, Uint8List data,
      InternetAddress target, int port) {
    try {
      socket.send(data, target, port);
      _sent++;
      _lastSentAt = DateTime.now();
    } catch (e) {
      _sendFailures++;
      _lastError = '发送 ${target.address}:$port 失败：${_brief(e)}';
      if (_looksClosed(e)) unawaited(_healSocket());
    }
  }

  bool _looksClosed(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('closed') || s.contains('bad file descriptor');
  }

  String _brief(Object e) {
    final s = '$e'.split('\n').first;
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  /// socket 自愈：被系统关闭后重新绑定端口并恢复监听。
  ///
  /// 真机教训：socket 静默死亡时 `running` 仍为 true，不重建的话表面上
  /// 「服务在跑」，实际永远收不到也发不出任何包。
  Future<void> _healSocket() async {
    if (_healing || _socket == null) return;
    _healing = true;
    try {
      await _subscription?.cancel();
      _subscription = null;
      _socket?.close();
      _socket = null;
      final socket = await _bindBeaconSocket();
      if (socket == null) {
        _lastError = '信标 socket 重建失败：端口被占用';
        return;
      }
      _socket = socket;
      _heals++;
      _subscription = socket.listen(_onSocketEvent, onError: (Object e) {
        _lastError = '接收异常：${_brief(e)}';
        if (_looksClosed(e)) unawaited(_healSocket());
      });
      // 重建后立刻补发一次信标，不必等下一个周期
      if (_broadcasting) unawaited(_sendBeacon());
    } catch (e) {
      _lastError = '信标 socket 重建异常：${_brief(e)}';
    } finally {
      _healing = false;
    }
  }

  /// 运行统计快照（设置页「网络诊断」）
  SyncDiscoveryStats get stats => SyncDiscoveryStats(
        sent: _sent,
        sendFailures: _sendFailures,
        received: _received,
        ignored: _ignored,
        lastSentAt: _lastSentAt,
        lastReceivedAt: _lastReceivedAt,
        lastError: _lastError,
        boundPort: _boundPorts.isEmpty ? 0 : _boundPorts.first,
        heals: _heals,
        interfaces: List<String>.unmodifiable(_scanInterfaces),
      );



  Future<void> _onSocketEvent(RawSocketEvent event) async {
    final socket = _socket;
    if (socket == null || event != RawSocketEvent.read) return;
    Datagram? dg;
    do {
      dg = socket.receive();
      if (dg != null) {
        handleDatagram(dg.data, dg.address);
      }
    } while (dg != null);
  }

  Future<void> _onSocketEventMcast(RawSocketEvent event) async {
    final socket = _mcastSocket;
    if (socket == null || event != RawSocketEvent.read) return;
    Datagram? dg;
    do {
      dg = socket.receive();
      if (dg != null) {
        handleDatagram(dg.data, dg.address);
      }
    } while (dg != null);
  }

  /// 处理一个收到的 UDP 包（抽出供单测直接调用，不走真实网卡）。
  /// 信标统一 UTF-8 编码（设备名含中文）。
  /// 单播扫描的关键机制：收到他端信标后单播应答自己的信标，
  /// 使「我扫到对端」与「对端扫到我」双向成立，互不依赖广播可达性
  void handleDatagram(Uint8List data, InternetAddress address) {
    String raw;
    try {
      raw = utf8.decode(data);
    } catch (_) {
      _ignored++;
      return;
    }
    final beacon = SyncBeacon.decode(raw);
    if (beacon == null) {
      _ignored++; // 他应用/非法包：单独计数，便于区分「没收到」与「解析不了」
      return;
    }
    if (beacon.deviceId == _selfDeviceId) return; // 忽略自己的回环
    _received++;
    _lastReceivedAt = DateTime.now();
    _mergeBeacon(beacon, address.address);
    // 应答机制：收到他端信标即单播回发自己的信标（节流），
    // 使单向扫描也能双向可见，不依赖双方都在扫描。
    unawaited(_replyBeaconTo(address));
  }

  /// 单播回发本机信标给信标来源（每地址节流，防扫描风暴）
  Future<void> _replyBeaconTo(InternetAddress target) async {
    final socket = _socket;
    final builder = buildBeacon;
    if (socket == null || builder == null || !_broadcasting) return;
    final now = DateTime.now();
    final last = _lastReplyAt[target.address];
    if (last != null && now.difference(last) < replyCooldown) return;
    _lastReplyAt[target.address] = now;
    try {
      final beacon = await builder();
      final data = Uint8List.fromList(utf8.encode(beacon.encode()));
      for (final port in const [primaryPort, fallbackPort]) {
        _safeSend(socket, data, target, port);
      }
    } catch (_) {
      // 信标构造失败下个周期重试，不影响发现主链路（已合并对端）
    }
  }

  void _mergeBeacon(SyncBeacon beacon, String ip) {
    final existing = _peers[beacon.deviceId];
    final now = DateTime.now();
    if (existing == null) {
      final peer = DiscoveredPeer(
        deviceId: beacon.deviceId,
        deviceName: beacon.deviceName,
        ip: ip,
        port: beacon.port,
        lastSeen: now,
      );
      _peers[beacon.deviceId] = peer;
      onPeersChanged?.call();
      onPeerDiscovered?.call(peer);
      return;
    }
    final changed = existing.deviceName != beacon.deviceName ||
        existing.ip != ip ||
        existing.port != beacon.port;
    _peers[beacon.deviceId] = existing.copyWith(
      deviceName: beacon.deviceName,
      ip: ip,
      port: beacon.port,
      lastSeen: now,
    );
    if (changed) onPeersChanged?.call();
  }

  /// 单测注入：不绑端口直接验证信标合并/去重逻辑
  @visibleForTesting
  set selfDeviceIdForTest(String id) => _selfDeviceId = id;

  /// 启停主动发现（广播 + 多播 + 子网扫描）。监听不受影响
  Future<void> setBroadcasting(bool enabled) async {
    if (enabled == _broadcasting) return;
    _broadcasting = enabled;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    if (!enabled) return;
    await _sendBeacon();
    unawaited(_subnetScan());
    _broadcastTimer = Timer.periodic(beaconInterval, (_) => _sendBeacon());
    _scanTimer = Timer.periodic(scanInterval, (_) => unawaited(_subnetScan()));
  }

  /// 广播 + 多播发送（辅助通道；单播扫描见 [_subnetScan]）
  ///
  /// 目标顺序按「可靠性」排：先各真实网段的定向广播，最后才是受限广播
  /// `255.255.255.255`（多网卡机器上它只走默认路由；历史上它还是把 socket
  /// 打死的那一发，所以永远不排第一）。
  Future<void> _sendBeacon() async {
    final socket = _socket;
    final builder = buildBeacon;
    if (socket == null || builder == null) return;
    try {
      final beacon = await builder();
      final data = Uint8List.fromList(utf8.encode(beacon.encode()));
      final interfaces = await _interfaces();
      final targets = LanAddress.broadcastTargets(interfaces);
      var n = 0;
      for (final target in targets) {
        for (final port in const [primaryPort, fallbackPort]) {
          _safeSend(socket, data, InternetAddress(target), port);
          // 每 8 个包让出事件循环：一口气几百个 UDP 写入会撞上系统发送缓冲上限
          if (++n % 8 == 0) await Future<void>.delayed(Duration.zero);
        }
      }
      // 受限广播兜底（掩码不是 /24 时只有它能覆盖到对端所在网段）
      for (final port in const [primaryPort, fallbackPort]) {
        _safeSend(
            socket, data, InternetAddress('255.255.255.255'), port);
      }
      // 多播通道
      final ms = _mcastSocket;
      if (ms != null) {
        try {
          ms.send(data, multicastGroup, multicastPort);
          _sent++;
          _lastSentAt = DateTime.now();
        } catch (e) {
          _sendFailures++;
          _lastError = '多播发送失败：${_brief(e)}';
        }
      }
    } catch (e) {
      // 信标构造失败（如设备名读取异常）下个周期重试，不影响监听
      _lastError = '信标构造失败：${_brief(e)}';
    }
  }

  /// 真实网卡列表（20 秒缓存：枚举网卡在移动端不算便宜）
  Future<List<LanInterface>> _interfaces() async {
    final now = DateTime.now();
    final cached = _ifaceCache;
    if (cached != null &&
        now.difference(_ifaceCacheAt) < const Duration(seconds: 20)) {
      return cached;
    }
    final list = await LanAddress.preferred();
    _ifaceCache = list;
    _ifaceCacheAt = now;
    _scanInterfaces = list.map((e) => '${e.name} (${e.address})').toList();
    return list;
  }

  /// 子网单播扫描（发现主力）：枚举本机各真实 IPv4 接口的 /24 网段，
  /// 对每个主机地址单播信标。单播属出站流量，不受入站防火墙规则限制，
  /// 也不依赖网络对广播的转发；配合 [handleDatagram] 的应答机制双向可见。
  ///
  /// 只扫真实网卡：VMware/Hyper-V/Docker 的虚拟网段纯属噪声（每轮多几百个包），
  /// 还会挤占真实网段的发送带宽。
  Future<void> _subnetScan() async {
    final socket = _socket;
    final builder = buildBeacon;
    if (socket == null || builder == null || _scanning) return;
    _scanning = true;
    try {
      final hosts = LanAddress.scanHosts(await _interfaces());
      if (hosts.isEmpty) return;
      final beacon = await builder();
      final data = Uint8List.fromList(utf8.encode(beacon.encode()));
      var idx = 0;
      for (final host in hosts) {
        for (final port in const [primaryPort, fallbackPort]) {
          _safeSend(socket, data, InternetAddress(host), port);
        }
        // 每 8 个地址让出事件循环，避免阻塞 UI/收发，也避免瞬时打爆发送缓冲
        if (++idx % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (_socket == null) return; // 扫描途中 socket 被重建/停止
        }
      }
    } catch (e) {
      // 接口枚举/发送异常不阻塞发现（广播/多播通道仍在）
      _lastError = '单播扫描异常：${_brief(e)}';
    } finally {
      _scanning = false;
    }
  }

  void _pruneAndNotify() {
    final before = _peers.length;
    _prunePeers(DateTime.now());
    if (_peers.length != before) onPeersChanged?.call();
  }

  void _prunePeers(DateTime now) {
    _peers.removeWhere(
        (_, p) => now.difference(p.lastSeen) > peerTimeout);
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _mcastSubscription?.cancel();
    _mcastSubscription = null;
    _socket?.close();
    _socket = null;
    _mcastSocket?.close();
    _mcastSocket = null;
    _broadcasting = false;
    _boundPorts.clear();
    _peers.clear();
    _lastReplyAt.clear();
  }
}

/// 避免引 flutter/foundation 的轻量回调别名（本层为纯 dart:io 服务）
typedef VoidCallbackLike = void Function();
