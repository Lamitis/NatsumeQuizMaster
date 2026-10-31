import 'dart:io';

/// 本机局域网的一张 IPv4 网卡地址：候选地址 + 是否虚拟网卡 + 排序分。
class LanInterface {
  const LanInterface({
    required this.name,
    required this.address,
    required this.virtualAdapter,
    required this.score,
  });

  /// 网卡名（Windows 上是「WLAN / 以太网 / VMware Network Adapter VMnet1」）
  final String name;

  /// 该网卡上的一个 IPv4 地址
  final String address;

  /// 是否虚拟网卡（VMware / Hyper-V / Docker / VPN / 蓝牙 …）
  final bool virtualAdapter;

  /// 越大越像「用户真正在用的那个局域网」
  final int score;

  @override
  String toString() => '$name ($address)';
}

/// 本机局域网地址的挑选与 /24 网段推算（纯计算 + 一次 NetworkInterface 枚举）。
///
/// 为什么需要它（2026-10-30 真机反馈「同 Wi-Fi 下永远发现不了设备」）：
///
/// 1. 装了 VMware / Hyper-V / Docker / 各类 VPN 的机器上，`NetworkInterface.list()`
///    会返回一堆**只在宿主机内部存在**的地址（例：`192.168.10.1` = VMnet1、
///    `172.27.240.1` = Hyper-V Default Switch），而且枚举顺序不稳定；
///    旧实现取「第一个非回环地址」，于是二维码里可能写进 VMnet1 的地址——
///    手机扫完拿着 `192.168.10.1:51630` 去连，永远连不上，界面却显示「已配对」。
/// 2. 对虚拟网段做广播/逐个主机单播扫描是纯噪声（每轮多扫几百个地址），
///    还会拖慢真实网段的发现节奏。
///
/// 因此这里统一做「可用性过滤 + 打分排序」，发现与配对都只认真实网卡优先。
class LanAddress {
  LanAddress._();

  /// 虚拟网卡名字特征（小写包含匹配）。
  ///
  /// 注意 `vether` 必须单列：Hyper-V 的 `vEthernet (Default Switch)` 名字里
  /// 含 `ethernet`，放在「真实网卡」规则前面判，才不会被误当物理网卡。
  static const List<String> _virtualHints = [
    'vmnet',
    'vmware',
    'virtualbox',
    'vbox',
    'vether',
    'hyper-v',
    'hyperv',
    'default switch',
    'docker',
    'wsl',
    'veth',
    'virbr',
    'br-',
    'tap-',
    'tun',
    'utun',
    'ppp',
    'tailscale',
    'zerotier',
    'wireguard',
    'hamachi',
    'radmin',
    'loopback',
    'bluetooth',
    '蓝牙',
  ];

  /// 物理网卡名字特征（锚定开头，避免 `vEthernet` 里的 `ethernet` 命中）
  static final RegExp _physicalName =
      RegExp(r'^(wl|wlan|wi-?fi|en|eth|enp|enx|eno|以太网|无线)');

  /// 地址是否可用（排除回环、APIPA 169.254、组播/保留、CGNAT）
  static bool isUsableAddress(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 0 || a == 127 || a >= 224) return false;
    if (a == 169 && b == 254) return false; // APIPA：本身就是没连上网络
    if (a == 100 && b >= 64 && b <= 127) return false; // 100.64/10：CGNAT
    return true;
  }

  /// 是否 RFC1918 私有地址（家用路由器基本都是）
  static bool isPrivateAddress(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  /// 网卡名是否像虚拟网卡
  static bool isVirtualName(String name) {
    final n = name.toLowerCase();
    for (final hint in _virtualHints) {
      if (n.contains(hint)) return true;
    }
    return false;
  }

  /// 打分：不可用返回 -1；私有网段 +40、非虚拟 +30、物理名字 +20
  static int scoreOf({required String name, required String address}) {
    if (!isUsableAddress(address)) return -1;
    var score = 10;
    if (isPrivateAddress(address)) score += 40;
    if (!isVirtualName(name)) score += 30;
    if (_physicalName.hasMatch(name.toLowerCase())) score += 20;
    return score;
  }

  /// 枚举本机全部可用 IPv4 地址（含虚拟网卡），按分数从高到低
  static Future<List<LanInterface>> candidates() async {
    final out = <LanInterface>[];
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final ni in ifaces) {
        for (final addr in ni.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final score = scoreOf(name: ni.name, address: addr.address);
          if (score < 0) continue;
          out.add(LanInterface(
            name: ni.name,
            address: addr.address,
            virtualAdapter: isVirtualName(ni.name),
            score: score,
          ));
        }
      }
    } catch (_) {
      // 枚举失败：交给调用方的空列表兜底（发现退回受限广播）
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  /// 真实网卡优先；一个真实网卡都没有时（极少见）才退回虚拟网卡
  static Future<List<LanInterface>> preferred() async {
    final all = await candidates();
    final real = all.where((c) => !c.virtualAdapter).toList();
    return real.isEmpty ? all : real;
  }

  /// 本机最适合写进二维码 / 交给对端连接的那个地址
  static Future<String?> primaryIpv4() async {
    final list = await preferred();
    return list.isEmpty ? null : list.first.address;
  }

  /// /24 网段的定向广播地址（掩码不是 /24 时由受限广播兜底）
  static String broadcastOf(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return '255.255.255.255';
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }

  /// 同 /24 网段内的全部主机地址（1..254，排除本机）
  static List<String> hostsOf(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return const [];
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    final out = <String>[];
    for (var i = 1; i < 255; i++) {
      final host = '$prefix.$i';
      if (host == ip) continue;
      out.add(host);
    }
    return out;
  }

  /// 扫描目标：每个网段只保留一份主机列表（多网卡同网段不重复扫）
  static List<String> scanHosts(List<LanInterface> interfaces) {
    final seenPrefix = <String>{};
    final out = <String>[];
    for (final ni in interfaces) {
      final parts = ni.address.split('.');
      if (parts.length != 4) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      if (!seenPrefix.add(prefix)) continue;
      out.addAll(hostsOf(ni.address));
    }
    return out;
  }

  /// 广播目标：每个网段一条定向广播（去重）
  static List<String> broadcastTargets(List<LanInterface> interfaces) {
    final out = <String>[];
    for (final ni in interfaces) {
      final target = broadcastOf(ni.address);
      if (!out.contains(target)) out.add(target);
    }
    return out;
  }
}
