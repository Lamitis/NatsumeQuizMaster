import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/plugin.dart';
import '../database_service.dart';
import '../export_storage.dart';
import 'plugin_loader.dart';

/// 第三方插件表（Natsume-Registry）客户端（v1.35）。
///
/// 分工写在最前面，避免后来者把「登记」误读成「审核」：
/// - 登记表只给**信息**（id / 版本 / 下载地址 / sha256），不托管文件、不审代码；
/// - 本客户端**只做机械校验**：字段白名单、域名白名单、下载后重算 sha256；
///   校验通过 ≠ 代码安全，所以安装必须由用户点确认，且必须先看过 disclaimer；
/// - 不自动安装、不静默升级：版本号变了只在列表里标「可更新」，点不点由用户；
/// - 拉表失败**不清空已有列表**（[fetch] 抛异常，调用方保留旧数据）。
///
/// 数据格式见 https://github.com/Lamitis/Natsume-Registry 。
class RegistryPlugin {
  const RegistryPlugin({
    required this.id,
    required this.name,
    required this.author,
    required this.version,
    required this.description,
    required this.downloadUrl,
    required this.sha256,
  });

  final String id;
  final String name;
  final String author;
  final String version;
  final String description;
  final String downloadUrl;

  /// 64 位小写十六进制
  final String sha256;

  /// 登记项的 7 个字段：多一个少一个都视为非法（表结构是契约）
  static const Set<String> fieldNames = {
    'id',
    'name',
    'author',
    'version',
    'description',
    'download_url',
    'sha256',
  };

  static final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{2,63}$');
  static final RegExp _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// 下载域名白名单：只允许 GitHub 系（发布包 / 原始文件 / codeload）
  static const Set<String> allowedHosts = {
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'raw.githubusercontent.com',
    'codeload.github.com',
  };

  /// 说明上限（表里约定 240 字）
  static const int maxDescriptionChars = 240;

  /// 逐字段校验；任何一条不合法返回 null（该条被丢弃，不影响同表其它条目）。
  static RegistryPlugin? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((k, v) => MapEntry(k.toString(), v));
    // 字段集合必须完全一致：防止未来加字段后老客户端「静默误解」
    if (map.keys.toSet().difference(fieldNames).isNotEmpty) return null;
    if (fieldNames.difference(map.keys.toSet()).isNotEmpty) return null;

    String str(String key) => map[key]?.toString().trim() ?? '';
    final id = str('id');
    final name = str('name');
    final author = str('author');
    final version = str('version');
    final description = str('description');
    final downloadUrl = str('download_url');
    final sha256Hex = str('sha256');

    if (!_idPattern.hasMatch(id)) return null;
    if (name.isEmpty || name.length > 60) return null;
    if (author.isEmpty || author.length > 60) return null;
    if (!_versionPattern.hasMatch(version)) return null;
    if (description.isEmpty || description.length > maxDescriptionChars) {
      return null;
    }
    if (!_sha256Pattern.hasMatch(sha256Hex)) return null;

    final uri = Uri.tryParse(downloadUrl);
    if (uri == null || uri.scheme != 'https') return null;
    if (!allowedHosts.contains(uri.host)) return null;
    if (uri.path.isEmpty || uri.path == '/') return null;

    return RegistryPlugin(
      id: id,
      name: name,
      author: author,
      version: version,
      description: description,
      downloadUrl: downloadUrl,
      sha256: sha256Hex,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'author': author,
        'version': version,
        'description': description,
        'download_url': downloadUrl,
        'sha256': sha256,
      };
}

/// 一次拉表的结果。空表是合法结果（`plugins: []`、`count: 0`），不是 404。
class RegistrySnapshot {
  const RegistrySnapshot({
    required this.schema,
    required this.generatedAt,
    required this.disclaimer,
    required this.plugins,
    this.droppedCount = 0,
  });

  final int schema;
  final String generatedAt;

  /// 必须能在界面上显示出来（登记 ≠ 审核）
  final String disclaimer;

  /// 已通过字段校验的条目
  final List<RegistryPlugin> plugins;

  /// 被字段校验丢掉的条目数（只用于文案提示，不弹错）
  final int droppedCount;

  bool get isEmpty => plugins.isEmpty;

  static const RegistrySnapshot empty = RegistrySnapshot(
    schema: 1,
    generatedAt: '',
    disclaimer: '',
    plugins: [],
  );

  /// 解析 `registry.json` 原文。
  ///
  /// 抛 [FormatException] 的情形只有「整表不可用」：不是 JSON、不是对象、
  /// `plugins` 不是数组。单条不合法只丢单条——一张表里混进一条坏数据，
  /// 不该让用户整张表都看不到。
  factory RegistrySnapshot.parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('registry.json 不是对象');
    final map = decoded.map((k, v) => MapEntry(k.toString(), v));
    final rawList = map['plugins'];
    if (rawList is! List) {
      throw const FormatException('registry.json 缺少 plugins 数组');
    }

    final valid = <RegistryPlugin>[];
    for (final raw in rawList) {
      final entry = RegistryPlugin.tryParse(raw);
      if (entry != null) valid.add(entry);
    }
    return RegistrySnapshot(
      schema: int.tryParse('${map['schema'] ?? 1}') ?? 1,
      generatedAt: (map['generated_at'] ?? '').toString(),
      disclaimer: (map['disclaimer'] ?? '').toString().trim(),
      plugins: valid,
      droppedCount: rawList.length - valid.length,
    );
  }
}

/// 安装结果（UI 用来提示「已安装 / 已更新到 x.y.z」）
class PluginInstallResult {
  const PluginInstallResult({
    required this.entry,
    required this.loaded,
    required this.installedDir,
    required this.updated,
  });

  final RegistryPlugin entry;
  final LoadedPlugin loaded;
  final String installedDir;

  /// true = 覆盖了旧版本
  final bool updated;
}

/// 拉表 / 安装失败的用户可读错误
class PluginRegistryException implements Exception {
  const PluginRegistryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 拉表 / 校验 / 安装。文件层与数据库层都在这里，UI 只负责确认与展示。
class PluginRegistryService {
  PluginRegistryService._();

  static final PluginRegistryService instance = PluginRegistryService._();

  /// 登记表地址（客户端唯一读的地址）
  static const String registryUrl =
      'https://raw.githubusercontent.com/Lamitis/Natsume-Registry/main/registry.json';

  /// 「已看过 disclaimer」的标记键：只认一次，之后安装不再反复弹
  static const String disclaimerAckKey = 'plugin_registry_disclaimer_ack_v1';

  static const Duration defaultTimeout = Duration(seconds: 12);

  final DatabaseService _db = DatabaseService.instance;

  /// 拉表。任何失败都抛 [PluginRegistryException]：
  /// 调用方据此提示「本次没拉到」，但**保留上一次成功的列表**。
  Future<RegistrySnapshot> fetch({
    String? url,
    http.Client? client,
    Duration timeout = defaultTimeout,
  }) async {
    final ownClient = client == null;
    final c = client ?? http.Client();
    try {
      final resp = await c.get(
        Uri.parse(url ?? registryUrl),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'NatsumeQuizMaster',
        },
      ).timeout(timeout);
      if (resp.statusCode != 200) {
        throw PluginRegistryException('插件表读取失败（HTTP ${resp.statusCode}）');
      }
      return RegistrySnapshot.parse(utf8.decode(resp.bodyBytes));
    } on TimeoutException {
      throw const PluginRegistryException('插件表读取超时，稍后自动重试');
    } on FormatException catch (e) {
      throw PluginRegistryException('插件表格式异常：${e.message}');
    } on http.ClientException catch (e) {
      throw PluginRegistryException('插件表连不上：${e.message}');
    } finally {
      if (ownClient) c.close();
    }
  }

  /// 下载字节的 sha256（小写十六进制）——测试与安装共用同一份实现
  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// 校验下载内容是否与登记表一致。不一致必须拒绝安装（安全红线）。
  static bool verifySha256(List<int> bytes, String expected) =>
      sha256Hex(bytes) == expected.toLowerCase();

  /// 用户是否已经看过并确认过 disclaimer
  Future<bool> hasAcceptedDisclaimer() async {
    final raw = await _db.getSetting(disclaimerAckKey);
    return (raw ?? '').trim().isNotEmpty;
  }

  /// 记下「已确认」：存时间戳而不是 bool，日后排查「哪次安装前看过」有据可查
  Future<void> acceptDisclaimer() =>
      _db.setSetting(disclaimerAckKey, DateTime.now().toIso8601String());

  /// 已安装插件（id → 插件行），用于「已安装 / 可更新」判断
  Future<Map<String, PluginInfo>> installedMap() async {
    final list = await _db.getAllPlugins();
    return {for (final p in list) p.id: p};
  }

  /// 该登记项相对本机状态：`install` / `update` / `installed`
  static String actionFor(RegistryPlugin entry, PluginInfo? installed) {
    if (installed == null) return 'install';
    return isNewer(entry.version, installed.version) ? 'update' : 'installed';
  }

  /// 语义化版本比较（只支持 `x.y.z`，与登记表字段规则一致）。
  /// candidate 比 installed 新返回 true。
  static bool isNewer(String candidate, String installed) {
    final a = _parseSemver(candidate);
    final b = _parseSemver(installed);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int>? _parseSemver(String raw) {
    final parts = raw.trim().split('.');
    if (parts.length != 3) return null;
    final out = <int>[];
    for (final part in parts) {
      final v = int.tryParse(part);
      if (v == null || v < 0) return null;
      out.add(v);
    }
    return out;
  }

  /// 插件安装根目录（与「导入插件」同一个目录，便于卸载时一起清）
  Future<Directory> pluginRoot() async {
    final base = await ExportStorage.resolve();
    final dir = Directory(p.join(base.path, 'plugins'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 下载 → 校验 sha256 → 解包 → 登记。
  ///
  /// 任何一步失败都会抛 [PluginRegistryException]，且**不留下半装状态**：
  /// 先解到 staging，id 也对得上才替换正式目录。
  Future<PluginInstallResult> install(
    RegistryPlugin entry, {
    http.Client? client,
    Duration timeout = defaultTimeout,
  }) async {
    final ownClient = client == null;
    final c = client ?? http.Client();
    final root = await pluginRoot();
    final installDir = Directory(p.join(root.path, entry.id));
    Directory? staging;
    try {
      final resp = await c.get(Uri.parse(entry.downloadUrl)).timeout(timeout);
      if (resp.statusCode != 200) {
        throw PluginRegistryException('插件包下载失败（HTTP ${resp.statusCode}）');
      }
      final bytes = resp.bodyBytes;
      if (!verifySha256(bytes, entry.sha256)) {
        throw const PluginRegistryException('sha256 校验失败：下载内容与登记表不一致，已拒绝安装');
      }

      staging = Directory.systemTemp.createTempSync('natsume_plugin_');
      final zip = File(p.join(staging.path, '${entry.id}.zip'))
        ..writeAsBytesSync(bytes);
      final staged = Directory(p.join(staging.path, 'unpacked'));
      final loaded = await PluginLoader.loadFromZip(zip.path, staged.path);
      if (loaded.manifest.id != entry.id) {
        throw PluginRegistryException(
            '插件包 id（${loaded.manifest.id}）与登记表（${entry.id}）不一致，已拒绝安装');
      }

      final existing = await _db.getPlugin(entry.id);
      if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      _copyDirectory(staged, installDir);

      final manifest = <String, dynamic>{
        ...loaded.manifest.toJson(),
        // 来源信息随清单落库：日后「这个插件哪来的、装的是哪个哈希」可查
        'registry': {
          'url': registryUrl,
          'download_url': entry.downloadUrl,
          'sha256': entry.sha256,
          'version': entry.version,
          'author': entry.author,
          'installed_at': DateTime.now().toIso8601String(),
        },
      };
      await _db.upsertPlugin(PluginInfo(
        id: entry.id,
        name: entry.name.isNotEmpty ? entry.name : loaded.manifest.name,
        // 版本以**插件包清单**为准：登记表只用来判断「有没有新版」
        version: loaded.manifest.version,
        author: entry.author,
        description: entry.description,
        manifest: jsonEncode(manifest),
        // 升级保留用户原来的启停状态
        enabled: existing?.enabled ?? true,
        installedAt: existing?.installedAt ?? DateTime.now().toIso8601String(),
      ));
      return PluginInstallResult(
        entry: entry,
        loaded: loaded,
        installedDir: installDir.path,
        updated: existing != null,
      );
    } on TimeoutException {
      throw const PluginRegistryException('插件包下载超时，请稍后重试');
    } on PluginRegistryException {
      rethrow;
    } catch (e) {
      throw PluginRegistryException('安装失败：$e');
    } finally {
      if (ownClient) c.close();
      if (staging != null && staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  static void _copyDirectory(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final e in from.listSync(recursive: true)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: from.path);
      final dest = File(p.join(to.path, rel));
      dest.parent.createSync(recursive: true);
      e.copySync(dest.path);
    }
  }
}
