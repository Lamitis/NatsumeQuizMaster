import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../debug_log_service.dart';
import '../device_service.dart';
import 'lan_address.dart';
import 'sync_discovery.dart';
import 'sync_code.dart';
import 'sync_models.dart';
import 'sync_pair_payload.dart';
import 'sync_repository.dart';
import 'sync_server.dart';

/// 配对状态机。
///
/// 真机反馈（2026-10-30）：旧实现只要本地保存了对端识别码就 `paired == true`，
/// 界面据此显示「已配对」——属于乐观 UI。码抄错了、对端没开、防火墙挡了、
/// 甚至不在同一网段，界面照样说已配对，用户以为连上了，实际一个包都发不出去。
///
/// 现在只有**对端确认之后**（带码握手返回 200，或同步成功）才进入
/// [SyncPairState.verified]，文案上才允许说「已配对」。
enum SyncPairState {
  /// 没有对端识别码
  none,

  /// 已保存识别码，但还没得到对端确认（等对端出现 / 等握手回执）
  awaitingPeer,

  /// 正在向对端核实识别码
  verifying,

  /// 对端已接受本机出示的识别码（握手成功，可正常同步）
  verified,

  /// 对端明确拒绝（识别码不匹配 / 临时码过期）
  rejected,
}

/// 状态的中文短标签（设置页状态行直接用）
extension SyncPairStateLabel on SyncPairState {
  String get label => switch (this) {
        SyncPairState.none => '未配对',
        SyncPairState.awaitingPeer => '等待对端确认',
        SyncPairState.verifying => '正在核实…',
        SyncPairState.verified => '已配对',
        SyncPairState.rejected => '识别码不匹配',
      };

  /// 只有核实过才算真的连上了
  bool get connected => this == SyncPairState.verified;
}

/// 局域网同步引擎：编排发现、传输与合并。
///
/// - 自动同步：开启后广播信标；发现新对端（收到其信标）自动触发同步
/// - 手动同步：设置页「立即同步」对已发现设备逐一同步
/// - 合并入口统一走 [SyncRepository]（按 uid upsert、批注按设备隔离）
/// - 同步完成后回调 [onSyncApplied]（刷新 AppState 题库/统计）
class SyncEngine extends ChangeNotifier {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  final SyncDiscovery _discovery = SyncDiscovery();
  final SyncServer _server = SyncServer();
  final SyncRepository _repository = SyncRepository();
  final http.Client _httpClient = http.Client();

  /// 自动同步的每设备冷却（避免两端互相发现时反复全量同步）
  static const Duration autoSyncCooldown = Duration(seconds: 120);
  static const Duration exchangeTimeout = Duration(seconds: 30);

  /// Android 组播/广播锁通道（Wi-Fi 默认丢广播包，持锁才能收到对端信标）
  static const MethodChannel _androidSyncChannel =
      MethodChannel('com.natsume.quiz/sync');

  bool _started = false;
  bool _autoSync = false;
  bool _syncing = false;
  DateTime? _lastSyncAt;
  String _statusMessage = '';
  final Map<String, DateTime> _lastAutoSyncAt = {};

  /// 本机设备码（长码，由 deviceId 派生；同一台设备恒定）
  String _deviceCode = '';

  /// 对端识别码（用户输入或扫码得到）。**为空时不发起任何同步**——
  /// 用户要求「接入端需要输入识别码才可以与目标设备进行自动同步」。
  String _peerCode = '';

  // ── 配对状态机 ──
  /// 是否已得到对端确认（未确认前界面不显示「已配对」）
  SyncPairState _pairState = SyncPairState.none;

  /// 状态的一句话说明（含失败原因，直接展示给用户）
  String _pairDetail = '';

  /// 已确认对端的名字 / 地址（发现通道失灵时仍可直连同步）
  String _verifiedPeerName = '';
  String _verifiedPeerIp = '';
  int _verifiedPeerPort = 0;

  /// 核实中标记（防重入：定时重试与「发现事件」可能同时触发）
  bool _verifying = false;
  Timer? _verifyTimer;

  /// 核实握手超时/重试节奏
  static const Duration pairVerifyTimeout = Duration(seconds: 3);
  static const Duration pairRetryInterval = Duration(seconds: 8);

  /// 扫码/确认后记下的对端地址（UDP 发现不到时的直连兜底）
  String? _scanIp;
  int? _scanPort;

  /// 本机临时码（6 位数字，一次性分享用）
  String _tempCode = '';
  DateTime? _tempExpiry;

  /// 同步范围：false=整库；true=只同步题库（用户之间分享题库）
  bool _banksOnly = false;

  /// 数据合并落库后回调（主入口用于刷新 AppState）
  void Function()? onSyncApplied;

  bool get started => _started;
  bool get autoSync => _autoSync;
  bool get syncing => _syncing;
  DateTime? get lastSyncAt => _lastSyncAt;
  String get statusMessage => _statusMessage;
  List<DiscoveredPeer> get peers => _discovery.peers;

  /// 本机设备码（展示给对端：可复制、可生成二维码）
  String get deviceCode => _deviceCode;

  /// 对端识别码（空 = 尚未配对，不会自动同步）
  String get peerCode => _peerCode;

  /// 是否**已经输入**对端识别码（门禁用：没输码一律不发请求）
  bool get paired => _peerCode.trim().isNotEmpty;

  /// 配对状态：只有对端确认过才是 [SyncPairState.verified]
  SyncPairState get pairState => _pairState;

  /// 对端是否已确认（UI 只认这个来显示「已配对」）
  bool get peerConfirmed => _pairState == SyncPairState.verified;

  /// 状态说明（含失败原因，UI 直接展示）
  String get pairDetail => _pairDetail;

  /// 已确认的对端（名字 + 地址），未确认时为空
  String get confirmedPeerName => _verifiedPeerName;

  /// 已确认对端地址（发现通道不通时「立即同步」用它直连）
  String get confirmedPeerAddress =>
      _verifiedPeerIp.isEmpty ? '' : '$_verifiedPeerIp:$_verifiedPeerPort';

  /// 本机当前临时码与是否仍有效
  String get tempCode => _tempCode;
  DateTime? get tempExpiry => _tempExpiry;
  bool get tempCodeAlive => SyncCode.tempCodeAlive(_tempCode, _tempExpiry);

  /// 同步范围：true=仅题库
  bool get banksOnly => _banksOnly;

  /// 启动：同步服务端常开（接收他端推送不依赖本机开关），
  /// 信标广播常开（否则双方都关自动同步时互相不可见，手动同步也没法用），
  /// [autoSync] 只控制「发现后是否自动触发同步」
  Future<void> start({required bool autoSync}) async {
    _autoSync = autoSync;
    if (_started) return;
    final deviceId = await DeviceService.instance.deviceId;
    _deviceCode = SyncCode.deviceCodeOf(deviceId);

    await _server.start(
      onReceived: (snapshot) async {
        final found = <SyncBankConflict>[];
        final merged =
            await _repository.importSnapshot(snapshot, conflictSink: found);
        _collectConflicts(found);
        if (merged > 0) {
          _lastSyncAt = DateTime.now();
          _statusMessage = '已接收并合并对端数据（$merged 项）';
          notifyListeners();
          onSyncApplied?.call();
        }
      },
      snapshot: ({required bool banksOnly}) =>
          _repository.exportSnapshot(banksOnly: banksOnly),
    );

    // 识别码门禁：设备长码 或 未过期的临时码，任一命中才放行
    _server.verifyCode = (presented) => SyncCode.accepts(
          presented: presented,
          deviceCode: _deviceCode,
          tempCode: tempCodeAlive ? _tempCode : null,
          tempExpiry: _tempExpiry,
        );

    _discovery.onPeerDiscovered = (peer) {
      DebugLogService.instance
          .log('SYNC', '发现设备：${peer.deviceName}（${peer.ip}:${peer.port}）');
      notifyListeners();
      // 有新对端出现：若还在等确认，立刻用它的地址补一次握手
      if (_peerCode.isNotEmpty && _pairState != SyncPairState.verified) {
        unawaited(verifyPairing());
      }
      if (_autoSync) unawaited(_autoSyncWith(peer));
    };
    _discovery.onPeersChanged = () => notifyListeners();

    await _discovery.start(
      deviceId: deviceId,
      beacon: () async => SyncBeacon(
        deviceId: deviceId,
        deviceName: await DeviceService.instance.deviceName,
        port: _server.port,
      ),
      broadcast: true, // 信标常广播（可被发现）；自动同步由 _autoSync 另行控制
    );

    // Android：获取组播/广播锁，否则 Wi-Fi 驱动会丢弃对端广播信标，
    // 表现为「接入局域网但发现不了设备」。失败降级（不阻塞启动）。
    if (Platform.isAndroid) {
      try {
        await _androidSyncChannel
            .invokeMethod('acquireMulticastLock')
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        DebugLogService.instance.log('SYNC', '组播锁获取失败（发现可能受限）: $e');
      }
    }

    _started = true;
    DebugLogService.instance.log(
        'SYNC', '同步服务已启动：HTTP 端口 ${_server.port}，自动同步=${autoSync ? "开" : "关"}');
    notifyListeners();
  }

  /// 自动同步开关切换（设置页）：只改「发现后是否自动同步」，
  /// 信标广播始终开启（关闭时仍可被发现与手动同步）
  Future<void> applyAutoSync(bool enabled) async {
    if (_autoSync == enabled) return;
    _autoSync = enabled;
    if (_started && enabled) {
      // 开启后立即与已发现的设备同步一次（不等下个信标周期）
      for (final peer in _discovery.peers) {
        unawaited(_autoSyncWith(peer));
      }
    }
    notifyListeners();
  }

  /// 保存对端识别码（用户手动输入或扫码得到）。空串 = 解除配对。
  ///
  /// 归一化后存储：去掉连字符/空格、统一大写，并宽容 O→0、I/L→1 的抄写误差。
  /// 6 位数字（临时码）保持数字形式原样。
  ///
  /// **这里不宣布「已配对」**：只把状态推进到 [SyncPairState.awaitingPeer]，
  /// 随后异步向对端核实（[verifyPairing]）。旧实现存完码就 `paired = true`，
  /// 界面于是直接显示「已配对」——正是用户报的「显示已配对但发现不了设备」。
  void applyPeerCode(String raw, {bool autoVerify = true}) {
    final normalized = SyncCode.normalize(raw);
    if (_peerCode == normalized) {
      // 同一个码再次提交：已核实过就保持，否则补一次核实（用户可能刚打开对端）
      if (normalized.isNotEmpty && autoVerify) unawaited(verifyPairing());
      return;
    }
    _peerCode = normalized;
    _verifiedPeerName = '';
    _verifiedPeerIp = '';
    _verifiedPeerPort = 0;
    if (normalized.isEmpty) {
      _pairState = SyncPairState.none;
      _pairDetail = '已解除配对，将不再自动同步';
      _statusMessage = _pairDetail;
      _stopVerifyTimer();
    } else {
      _pairState = SyncPairState.awaitingPeer;
      _pairDetail = '已保存识别码，正在等待对端确认…';
      _statusMessage = _pairDetail;
    }
    DebugLogService.instance.log(
        'SYNC', normalized.isEmpty ? '解除配对' : '已保存对端识别码，等待对端确认');
    notifyListeners();
    if (normalized.isNotEmpty && autoVerify) unawaited(verifyPairing());
  }

  /// 向对端核实识别码（握手）：带码请求对端的 `GET /sync/info`。
  ///
  /// - 200 → 对端接受了本机出示的码 → [SyncPairState.verified]（这才叫已配对）
  /// - 403 → 码不对 / 临时码过期 → [SyncPairState.rejected]（明确报错）
  /// - 连不上 → 保持 [SyncPairState.awaitingPeer]，8 秒后自动重试
  ///
  /// 顺带充当连通性探针：能拿到 200 说明 IP、端口、防火墙这条链路是通的，
  /// 后续 `/sync/exchange` 必然也走得通，不会再出现「界面已配对、实际发不出去」。
  Future<void> verifyPairing() async {
    if (_peerCode.isEmpty || _verifying) return;
    // 候选目标：已发现的对端 + 扫码/历史确认过的地址
    final targets = <_PairTarget>[];
    for (final peer in _discovery.peers) {
      targets.add(
          _PairTarget(ip: peer.ip, port: peer.port, name: peer.deviceName));
    }
    final scanIp = _scanIp;
    final scanPort = _scanPort;
    if (scanIp != null &&
        scanPort != null &&
        scanPort > 0 &&
        !targets.any((t) => t.ip == scanIp && t.port == scanPort)) {
      targets.add(_PairTarget(ip: scanIp, port: scanPort, name: ''));
    }
    if (targets.isEmpty) {
      _pairState = SyncPairState.awaitingPeer;
      _pairDetail = '已保存识别码，但还没发现对端：请确认两台设备连同一个 Wi-Fi、'
          '对端应用在前台；Windows 端还需在「网络诊断」里放行防火墙';
      notifyListeners();
      _ensureVerifyTimer();
      return;
    }

    _verifying = true;
    if (_pairState != SyncPairState.verified) {
      _pairState = SyncPairState.verifying;
      _pairDetail = '正在向对端核实识别码…';
      notifyListeners();
    }
    try {
      String? lastError;
      for (final target in targets) {
        final result = await _handshakeWith(target);
        if (result.state == SyncPairState.verified) {
          _pairState = SyncPairState.verified;
          _verifiedPeerIp = target.ip;
          _verifiedPeerPort = target.port;
          _verifiedPeerName = result.deviceName.isNotEmpty
              ? result.deviceName
              : (target.name.isNotEmpty
                  ? target.name
                  : '${target.ip}:${target.port}');
          _pairDetail = '已配对：$_verifiedPeerName（${target.ip}:${target.port}）'
              '已接受本机识别码';
          _statusMessage = _pairDetail;
          DebugLogService.instance.log('SYNC', '配对已确认：$_verifiedPeerName');
          _stopVerifyTimer();
          return;
        }
        if (result.state == SyncPairState.rejected) {
          _pairState = SyncPairState.rejected;
          _pairDetail = '识别码不匹配：对端拒绝了本机出示的识别码'
              '（请核对是否抄错，或临时码已过期）';
          _statusMessage = _pairDetail;
          _stopVerifyTimer();
          return;
        }
        lastError = result.error;
      }
      _pairState = SyncPairState.awaitingPeer;
      _pairDetail = '已保存识别码，但连不上对端'
          '${lastError == null ? '' : '（$lastError）'}'
          '：请确认对端已启动、在同一 Wi-Fi，且防火墙已放行';
      _ensureVerifyTimer();
    } finally {
      _verifying = false;
      notifyListeners();
    }
  }

  /// 向单个目标做一次带码握手
  Future<({SyncPairState state, String deviceName, String? error})>
      _handshakeWith(_PairTarget target) async {
    try {
      final uri = Uri.parse('http://${target.ip}:${target.port}/sync/info');
      final response = await _httpClient
          .get(uri, headers: {SyncServer.codeHeader: _peerCode})
          .timeout(pairVerifyTimeout);
      if (response.statusCode == 200) {
        var name = '';
        try {
          final dynamic body = jsonDecode(utf8.decode(response.bodyBytes));
          if (body is Map<String, dynamic> && body['device_name'] is String) {
            name = body['device_name'] as String;
          }
        } catch (_) {
          // 只取名字，解析失败不影响「已确认」这个结论
        }
        return (state: SyncPairState.verified, deviceName: name, error: null);
      }
      if (response.statusCode == 403) {
        return (
          state: SyncPairState.rejected,
          deviceName: '',
          error: '识别码被拒绝',
        );
      }
      return (
        state: SyncPairState.awaitingPeer,
        deviceName: '',
        error: 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      return (
        state: SyncPairState.awaitingPeer,
        deviceName: '',
        error: _brief(e),
      );
    }
  }

  /// 未确认前每 [pairRetryInterval] 重试一次握手（对端可能刚启动/刚开码）
  void _ensureVerifyTimer() {
    if (_peerCode.isEmpty || _pairState == SyncPairState.verified) {
      _stopVerifyTimer();
      return;
    }
    _verifyTimer ??= Timer.periodic(pairRetryInterval, (_) {
      if (_peerCode.isEmpty || _pairState == SyncPairState.verified) {
        _stopVerifyTimer();
        return;
      }
      unawaited(verifyPairing());
    });
  }

  void _stopVerifyTimer() {
    _verifyTimer?.cancel();
    _verifyTimer = null;
  }

  /// 同步成功即等价于握手成功：据此刻下「已配对」与对端地址
  void _markVerified(DiscoveredPeer peer) {
    _pairState = SyncPairState.verified;
    _verifiedPeerName = peer.deviceName;
    _verifiedPeerIp = peer.ip;
    _verifiedPeerPort = peer.port;
    _pairDetail = '已配对：${peer.deviceName}（${peer.ip}:${peer.port}）';
    _stopVerifyTimer();
  }

  /// 已确认过的对端（发现通道失灵时用它直连）
  DiscoveredPeer? _confirmedPeer() {
    if (_verifiedPeerIp.isEmpty || _verifiedPeerPort <= 0) return null;
    return DiscoveredPeer(
      deviceId: 'verified:$_verifiedPeerIp:$_verifiedPeerPort',
      deviceName:
          _verifiedPeerName.isEmpty ? _verifiedPeerIp : _verifiedPeerName,
      ip: _verifiedPeerIp,
      port: _verifiedPeerPort,
      lastSeen: DateTime.now(),
    );
  }

  /// 生成 6 位临时码（当面分享题库这种一次性场景），默认 10 分钟有效。
  void generateTempCode() {
    _tempCode = SyncCode.generateTempCode();
    _tempExpiry = DateTime.now().add(SyncCode.tempCodeTtl);
    notifyListeners();
  }

  /// 立即作废本机临时码（分享完毕即可关闭）
  void clearTempCode() {
    if (_tempCode.isEmpty && _tempExpiry == null) return;
    _tempCode = '';
    _tempExpiry = null;
    notifyListeners();
  }

  /// 切换同步范围：true = 只同步题库（用户之间分享题库），false = 整库。
  void applyBanksOnly(bool banksOnly) {
    if (_banksOnly == banksOnly) return;
    _banksOnly = banksOnly;
    notifyListeners();
  }

  // ── 同名题库冲突（2026-10-09 用户要求「若不一样则提示是否覆盖或者增添」）──

  final List<SyncBankConflict> _pendingConflicts = [];

  /// 待用户决策的同名题库冲突。挂在内存里即可：冲突本身带着对端数据，
  /// 而且下次同步会再次发现（对端快照每次都带它的题库）。
  List<SyncBankConflict> get pendingConflicts =>
      List.unmodifiable(_pendingConflicts);

  bool get hasPendingConflicts => _pendingConflicts.isNotEmpty;

  void _collectConflicts(List<SyncBankConflict> found) {
    if (found.isEmpty) return;
    for (final c in found) {
      final dup = _pendingConflicts
          .any((e) => e.name == c.name && e.peerBankUid == c.peerBankUid);
      if (!dup) _pendingConflicts.add(c);
    }
    _statusMessage = '有 ${_pendingConflicts.length} 个同名题库待处理';
    notifyListeners();
  }

  /// 用户在首页决定：覆盖（用对端整套替换）或 增添（只并对方多出来的题）。
  /// 返回受影响的题目数。
  Future<int> resolveConflict(SyncBankConflict conflict,
      {required bool overwrite}) async {
    final affected =
        await _repository.resolveBankConflict(conflict, overwrite: overwrite);
    _pendingConflicts.removeWhere((e) =>
        e.name == conflict.name && e.peerBankUid == conflict.peerBankUid);
    _statusMessage = overwrite
        ? '已覆盖「${conflict.name}」（$affected 题）'
        : '已增添「${conflict.name}」（$affected 题）';
    notifyListeners();
    onSyncApplied?.call();
    return affected;
  }

  /// 暂不处理：从待办里移除，本机数据保持不动。
  void dismissConflict(SyncBankConflict conflict) {
    _pendingConflicts.removeWhere((e) =>
        e.name == conflict.name && e.peerBankUid == conflict.peerBankUid);
    notifyListeners();
  }

  /// 本机在局域网里的 IPv4 地址（生成配对二维码时带上，对方扫完可立即同步）
  ///
  /// 走 [LanAddress]：真实网卡优先，虚拟网卡（VMware/Hyper-V/Docker/VPN）
  /// 排最后。旧实现取「第一个非回环地址」，在开了 VMware 的机器上可能把
  /// `192.168.10.1`（VMnet1）写进二维码 —— 手机扫完永远连不上。
  Future<String?> localIpv4() => LanAddress.primaryIpv4();

  /// 本机全部可用地址及其网卡名（「网络诊断」用：用户可对照路由器确认哪个是真的）
  Future<List<LanInterface>> localInterfaces() => LanAddress.candidates();

  /// 同步 HTTP 服务端口（0 = 未启动）
  int get httpPort => _server.port;

  /// 发现通道运行统计（「网络诊断」展示已发/已收包数：
  /// 已发 > 0 而已收 = 0，基本就是入站被防火墙挡了）
  SyncDiscoveryStats get discoveryStats => _discovery.stats;

  /// 生成配对载荷：识别码 + 设备名 + 当前地址。
  /// 地址只是加速项（DHCP 会变），UDP 发现仍是主力。
  Future<SyncPairPayload> buildPairPayload() async {
    final ip = await localIpv4();
    return SyncPairPayload(
      code: _deviceCode,
      deviceName: await DeviceService.instance.deviceName,
      ip: ip,
      port: _server.port > 0 ? _server.port : null,
    );
  }

  /// 扫码配对：保存识别码 → **向对端核实** → 二维码带地址时顺带立即同步一次。
  ///
  /// 返回值 = 是否**已确认连得上**。旧实现无条件 return true，UI 于是一路显示
  /// 「已配对」，而实际上对方可能根本没收到任何东西（用户报的第三个问题）。
  Future<bool> pairFromScan(SyncPairPayload payload) async {
    if (payload.hasAddress) {
      _scanIp = payload.ip;
      _scanPort = payload.port;
    }
    applyPeerCode(payload.code, autoVerify: false);
    if (!payload.hasAddress) {
      // 没带地址：只能靠发现（或此前确认过的地址）
      await verifyPairing();
      return _pairState == SyncPairState.verified;
    }
    final peer = DiscoveredPeer(
      deviceId: 'scan:${payload.ip}:${payload.port}',
      deviceName: payload.deviceName.isEmpty ? payload.ip! : payload.deviceName,
      ip: payload.ip!,
      port: payload.port!,
      lastSeen: DateTime.now(),
    );
    final ok = await syncWith(peer, source: '扫码');
    if (!ok) {
      // 同步失败也要把状态摆正（拒绝 / 连不上 / 等待确认），别留在「乐观已配对」
      await verifyPairing();
    }
    return ok || _pairState == SyncPairState.verified;
  }

  Future<void> _autoSyncWith(DiscoveredPeer peer) async {
    if (_syncing) return;
    // 未配对（没输入对端识别码）时绝不自动同步
    if (!paired) return;
    final last = _lastAutoSyncAt[peer.deviceId];
    if (last != null && DateTime.now().difference(last) < autoSyncCooldown) {
      return; // 冷却期内，等下次发现事件
    }
    _lastAutoSyncAt[peer.deviceId] = DateTime.now();
    await syncWith(peer, source: '自动');
  }

  /// 手动「立即同步」：对已发现设备逐一同步。
  ///
  /// 一个都没发现时不再干巴巴返回 (0,0)：先用已确认过的地址直连试一次
  /// （发现通道可能被防火墙挡住，但直连仍可能通），再退回到握手核实行，
  /// 让用户看到**具体原因**（没发现 / 连不上 / 码不对）。
  /// 返回 (尝试数, 成功数)
  Future<(int, int)> manualSync() async {
    // 未配对时明确提示，而不是静默什么都不做
    if (!paired) {
      _statusMessage = '请先输入对端识别码再同步';
      notifyListeners();
      return (0, 0);
    }
    var targets = _discovery.peers;
    if (targets.isEmpty) {
      final confirmed = _confirmedPeer();
      if (confirmed != null) {
        final ok = await syncWith(confirmed, source: '手动');
        return (1, ok ? 1 : 0);
      }
      await verifyPairing();
      _statusMessage = _pairDetail.isEmpty ? '未发现其他设备' : _pairDetail;
      notifyListeners();
      return (0, 0);
    }
    var ok = 0;
    for (final peer in targets) {
      final success = await syncWith(peer, source: '手动');
      if (success) ok++;
    }
    return (targets.length, ok);
  }

  /// 与单个对端同步：推送本机快照 → 对端合并并回传其快照 → 本机合并。
  /// 返回是否成功
  Future<bool> syncWith(DiscoveredPeer peer, {String source = '手动'}) async {
    if (_syncing) return false;
    // 识别码是硬门禁：没配对就不发请求（用户要求「接入端需要输入识别码
    // 才可以与目标设备进行自动同步」）
    if (!paired) {
      _statusMessage = '请先输入对端识别码再同步';
      notifyListeners();
      return false;
    }
    _syncing = true;
    _statusMessage = '正在与 ${peer.deviceName} 同步...';
    notifyListeners();
    try {
      final mySnapshot =
          await _repository.exportSnapshot(banksOnly: _banksOnly);
      final payload = utf8.encode(jsonEncode(mySnapshot));
      // 图片随同步走，但 64MB 单次上限是硬约束：超限给出清晰错误，
      // 不把大半请求发过去让对端拒收
      if (payload.length > SyncServer.maxBodyBytes) {
        throw Exception(
            '同步数据 ${(payload.length / 1048576).toStringAsFixed(1)}MB 超过 64MB 上限'
            '（题库配图较多），请减少同步范围');
      }
      final uri = Uri.parse('http://${peer.ip}:${peer.port}/sync/exchange');
      final response = await _httpClient
          .post(uri,
              headers: {
                'Content-Type': 'application/json; charset=utf-8',
                SyncServer.codeHeader: _peerCode,
                SyncServer.scopeHeader: _banksOnly ? 'banks' : 'full',
              },
              body: payload)
          .timeout(exchangeTimeout);
      if (response.statusCode == 403) {
        // 对端明确拒绝：状态直接判为「不匹配」，不再假装已配对
        _pairState = SyncPairState.rejected;
        _pairDetail = '识别码不匹配：对端拒绝了本次同步'
            '（请核对识别码是否抄错，或临时码已过期）';
        _stopVerifyTimer();
        throw Exception('识别码不匹配，对端拒绝了本次同步');
      }
      if (response.statusCode != 200) {
        throw Exception('对端返回 ${response.statusCode}');
      }
      final dynamic parsed = jsonDecode(utf8.decode(response.bodyBytes));
      if (parsed is Map<String, dynamic>) {
        final found = <SyncBankConflict>[];
        final merged =
            await _repository.importSnapshot(parsed, conflictSink: found);
        _collectConflicts(found);
        if (merged > 0) onSyncApplied?.call();
      }
      _lastSyncAt = DateTime.now();
      // 同步成功 = 对端已接受本机识别码：这时才允许显示「已配对」
      _markVerified(peer);
      _scanIp = peer.ip;
      _scanPort = peer.port;
      _statusMessage = '$source同步完成：${peer.deviceName}';
      DebugLogService.instance.log('SYNC', '与 ${peer.deviceName} 同步成功');
      return true;
    } catch (e) {
      _statusMessage = '同步失败：${peer.deviceName}（${_brief(e)}）';
      DebugLogService.instance.log('SYNC', '与 ${peer.deviceName} 同步失败: $e');
      return false;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  String _brief(Object e) {
    final s = '$e';
    final first = s.split('\n').first;
    return first.length > 60 ? '${first.substring(0, 60)}...' : first;
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      try {
        await _androidSyncChannel
            .invokeMethod('releaseMulticastLock')
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await _discovery.stop();
    await _server.stop();
    _stopVerifyTimer();
    _httpClient.close();
    _started = false;
  }
}

/// 握手目标：已发现的对端，或二维码/历史确认里的地址
class _PairTarget {
  const _PairTarget({required this.ip, required this.port, required this.name});

  final String ip;
  final int port;

  /// 已知的对端名（发现得到的）；只有地址时为空
  final String name;
}
