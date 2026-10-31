import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/services/sync/lan_address.dart';

/// 局域网地址挑选的纯逻辑回归（不碰真实网卡）。
///
/// 这些规则直接决定「二维码里写哪个 IP」和「广播/扫描往哪些网段发」：
/// 2026-10-30 真机反馈「同 Wi-Fi 下永远发现不了设备」的根因之一就是
/// 旧实现取「第一个非回环地址」，在装了 VMware 的机器上会选到 VMnet1。
void main() {
  group('isUsableAddress', () {
    test('排除回环 / APIPA / CGNAT / 组播 / 非法地址', () {
      expect(LanAddress.isUsableAddress('127.0.0.1'), isFalse);
      expect(LanAddress.isUsableAddress('169.254.13.7'), isFalse);
      expect(LanAddress.isUsableAddress('100.64.1.1'), isFalse);
      expect(LanAddress.isUsableAddress('100.127.255.254'), isFalse);
      expect(LanAddress.isUsableAddress('224.0.0.1'), isFalse);
      expect(LanAddress.isUsableAddress('255.255.255.255'), isFalse);
      expect(LanAddress.isUsableAddress('0.0.0.0'), isFalse);
      expect(LanAddress.isUsableAddress('192.168.1'), isFalse);
      expect(LanAddress.isUsableAddress('fe80::1'), isFalse);
    });

    test('接受常见家用/校园网段', () {
      expect(LanAddress.isUsableAddress('192.168.1.34'), isTrue);
      expect(LanAddress.isUsableAddress('10.20.30.40'), isTrue);
      expect(LanAddress.isUsableAddress('172.20.5.9'), isTrue);
      // 100.128+ 不在 CGNAT 100.64/10 里
      expect(LanAddress.isUsableAddress('100.128.1.1'), isTrue);
    });
  });

  group('isPrivateAddress', () {
    test('只认 RFC1918', () {
      expect(LanAddress.isPrivateAddress('10.1.2.3'), isTrue);
      expect(LanAddress.isPrivateAddress('192.168.0.5'), isTrue);
      expect(LanAddress.isPrivateAddress('172.16.0.1'), isTrue);
      expect(LanAddress.isPrivateAddress('172.31.255.254'), isTrue);
      expect(LanAddress.isPrivateAddress('172.32.0.1'), isFalse);
      expect(LanAddress.isPrivateAddress('172.15.0.1'), isFalse);
      expect(LanAddress.isPrivateAddress('8.8.8.8'), isFalse);
    });
  });

  group('isVirtualName', () {
    test('识别虚拟机 / 容器 / VPN / 蓝牙网卡', () {
      for (final name in [
        'VMware Network Adapter VMnet1',
        'VMware Network Adapter VMnet8',
        'vEthernet (Default Switch)',
        'Hyper-V Virtual Ethernet Adapter',
        'VirtualBox Host-Only Network',
        'Docker0',
        'br-1a2b3c4d',
        'veth3f2a',
        'Tailscale',
        'ZeroTier One [1.2.3]',
        'WireGuard Tunnel',
        'tun0',
        'ppp0',
        'Bluetooth 网络连接',
        '蓝牙网络连接',
        'Loopback Pseudo-Interface 1',
      ]) {
        expect(LanAddress.isVirtualName(name), isTrue, reason: name);
      }
    });

    test('真实网卡不误判', () {
      for (final name in [
        'WLAN',
        'Wi-Fi',
        '以太网',
        '无线网络连接',
        'eth0',
        'enp3s0',
        'en0',
        'wlan0',
        'wlp2s0',
      ]) {
        expect(LanAddress.isVirtualName(name), isFalse, reason: name);
      }
    });

    test('vEthernet 不能因为含 ethernet 被当成物理网卡', () {
      expect(LanAddress.isVirtualName('vEthernet (WSL)'), isTrue);
      expect(LanAddress.isVirtualName('ethernet 2'), isFalse);
    });
  });

  group('scoreOf', () {
    test('不可用地址返回 -1', () {
      expect(LanAddress.scoreOf(name: 'WLAN', address: '127.0.0.1'), -1);
      expect(LanAddress.scoreOf(name: 'WLAN', address: '169.254.1.1'), -1);
    });

    test('真实网卡私有地址 > 真实网卡公网地址 > 虚拟网卡私有地址', () {
      final realPrivate =
          LanAddress.scoreOf(name: 'WLAN', address: '192.168.1.34');
      final realPublic =
          LanAddress.scoreOf(name: 'WLAN', address: '203.0.113.9');
      final vmPrivate = LanAddress.scoreOf(
          name: 'VMware Network Adapter VMnet1', address: '192.168.10.1');
      expect(realPrivate, greaterThan(realPublic));
      expect(realPublic, greaterThan(vmPrivate));
    });

    test('物理网卡名有额外加分', () {
      final named = LanAddress.scoreOf(name: 'WLAN', address: '192.168.1.34');
      final weird = LanAddress.scoreOf(name: '网卡 3', address: '192.168.1.34');
      expect(named, greaterThan(weird));
    });
  });

  group('broadcastOf / hostsOf', () {
    test('/24 定向广播', () {
      expect(LanAddress.broadcastOf('192.168.1.34'), '192.168.1.255');
      expect(LanAddress.broadcastOf('10.0.0.7'), '10.0.0.255');
      expect(LanAddress.broadcastOf('not-an-ip'), '255.255.255.255');
    });

    test('主机列表 1..254 且排除自己', () {
      final hosts = LanAddress.hostsOf('192.168.1.34');
      expect(hosts.length, 253);
      expect(hosts.contains('192.168.1.34'), isFalse);
      expect(hosts.contains('192.168.1.1'), isTrue);
      expect(hosts.contains('192.168.1.254'), isTrue);
      expect(hosts.contains('192.168.1.0'), isFalse);
      expect(hosts.contains('192.168.1.255'), isFalse);
      expect(LanAddress.hostsOf('bad'), isEmpty);
    });
  });

  group('scanHosts / broadcastTargets', () {
    const wifi = LanInterface(
        name: 'WLAN',
        address: '192.168.1.34',
        virtualAdapter: false,
        score: 100);
    const wired = LanInterface(
        name: '以太网',
        address: '192.168.1.9',
        virtualAdapter: false,
        score: 90);
    const vm = LanInterface(
        name: 'VMware Network Adapter VMnet1',
        address: '192.168.10.1',
        virtualAdapter: true,
        score: 50);
    const vm2 = LanInterface(
        name: 'VMware Network Adapter VMnet8',
        address: '192.168.10.2',
        virtualAdapter: true,
        score: 45);

    test('同网段多网卡只扫一份，不重复扫', () {
      final hosts = LanAddress.scanHosts([wifi, wired, vm, vm2]);
      // 192.168.1.x（253）+ 192.168.10.x（253）
      expect(hosts.length, 506);
      expect(hosts.toSet().length, hosts.length);
      expect(hosts.where((h) => h.startsWith('192.168.1.')).length, 253);
      expect(hosts.where((h) => h.startsWith('192.168.10.')).length, 253);
    });

    test('定向广播按网段去重', () {
      final targets = LanAddress.broadcastTargets([wifi, wired, vm, vm2]);
      expect(targets, ['192.168.1.255', '192.168.10.255']);
    });

    test('空列表安全', () {
      expect(LanAddress.scanHosts(const []), isEmpty);
      expect(LanAddress.broadcastTargets(const []), isEmpty);
    });
  });

  group('真实网卡（本机环境冒烟）', () {
    testWidgets('candidates 结果按分数降序且地址可用', (tester) async {
      final list = await tester.runAsync(LanAddress.candidates) ?? const [];
      for (var i = 0; i < list.length; i++) {
        expect(LanAddress.isUsableAddress(list[i].address), isTrue,
            reason: list[i].address);
        expect(list[i].virtualAdapter, LanAddress.isVirtualName(list[i].name));
        if (i > 0) {
          expect(list[i - 1].score, greaterThanOrEqualTo(list[i].score));
        }
      }
    });

    testWidgets('primaryIpv4 选到的是可用地址', (tester) async {
      final ip = await tester.runAsync(LanAddress.primaryIpv4);
      if (ip != null) {
        expect(LanAddress.isUsableAddress(ip), isTrue, reason: ip);
      }
    });
  });
}
