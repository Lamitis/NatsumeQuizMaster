import 'dart:convert';

import 'package:http/http.dart' as http;

/// Syncthing REST API 客户端（v13 · 参考 syncthing `man/syncthing-rest-api.7`）。
///
/// 只封装同步所需的几个端点：系统状态（拿设备 ID）、配置读写（加设备/加目录）、
/// 目录状态（判断是否同步完成）。运行中的 Syncthing 实例由外层负责拉起
/// （桌面端捆绑二进制 / Android 端 gomobile 库），本客户端只负责用 HTTP 控制。
class SyncthingClient {
  final String baseUrl;
  final String apiKey;
  final http.Client client;

  SyncthingClient({
    this.baseUrl = 'http://127.0.0.1:8384',
    required this.apiKey,
    http.Client? client,
  }) : client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-API-Key': apiKey,
      };

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<bool> ping() async {
    try {
      final r = await client
          .get(_u('/rest/system/version'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String> myDeviceId() async {
    final r = await client
        .get(_u('/rest/system/status'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('无法获取设备 ID（${r.statusCode}）');
    final data = jsonDecode(r.body);
    return (data is Map ? (data['myID'] ?? '') : '').toString();
  }

  Future<Map<String, dynamic>> getConfig() async {
    final r = await client
        .get(_u('/rest/config'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('读取配置失败（${r.statusCode}）');
    final data = jsonDecode(r.body);
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<void> setConfig(Map<String, dynamic> config) async {
    final r = await client
        .put(_u('/rest/config'),
            headers: _headers, body: jsonEncode(config))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('写入配置失败（${r.statusCode}）');
  }

  /// 向配置中加入一个设备（已存在则跳过）。
  Map<String, dynamic> addDevice(
      Map<String, dynamic> config, String deviceId, String name) {
    final devices = (config['devices'] as List?) ?? [];
    final exists = devices.any((d) => d is Map && d['deviceID'] == deviceId);
    if (!exists) {
      devices.add({
        'deviceID': deviceId,
        'name': name,
        'addresses': ['dynamic'],
        'compression': 'metadata',
      });
    }
    config['devices'] = devices;
    return config;
  }

  /// 向配置中加入一个共享目录（已存在则跳过；把 [deviceIds] 加入该目录的
  /// 设备列表）。[path] 为目录在本机的绝对路径。
  Map<String, dynamic> addFolder(
    Map<String, dynamic> config,
    String folderId,
    String label,
    String path,
    List<String> deviceIds,
  ) {
    final folders = (config['folders'] as List?) ?? [];
    Map<String, dynamic>? target;
    for (final f in folders) {
      if (f is Map && f['id'] == folderId) {
        target = Map<String, dynamic>.from(f);
      }
    }
    target ??= <String, dynamic>{};
    target['id'] = folderId;
    target['label'] = label;
    target['path'] = path;
    target['type'] = 'sendreceive';
    final fDevices = (target['devices'] as List?) ?? [];
    for (final id in deviceIds) {
      if (!fDevices.any((d) => d is Map && d['deviceID'] == id)) {
        fDevices.add({'deviceID': id});
      }
    }
    target['devices'] = fDevices;
    if (!folders.any((f) => f is Map && f['id'] == folderId)) {
      folders.add(target);
    }
    config['folders'] = folders;
    return config;
  }

  Future<Map<String, dynamic>> folderStatus(String folderId) async {
    final r = await client
        .get(_u('/rest/db/status', {'folder': folderId}), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return <String, dynamic>{};
    final data = jsonDecode(r.body);
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  void dispose() => client.close();
}
