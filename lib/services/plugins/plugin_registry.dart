import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/plugin.dart';
import '../database_service.dart';
import '../export_storage.dart';
import '../net/smart_http_client.dart';
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
    this.category,
    this.tags = const [],
    this.permissions = const [],
    this.repoUrl,
    this.changelogUrl,
  });

  final String id;
  final String name;
  final String author;
  final String version;
  final String description;
  final String downloadUrl;

  /// 64 位小写十六进制
  final String sha256;

  /// 分类（v1.36 可选）：自由文案，市场页按它分组 / 筛选；空 = 「未分类」
  final String? category;

  /// 标签（v1.36 可选）：最多 [maxTags] 个，参与搜索
  final List<String> tags;

  /// **声明**会用到的本机能力（v1.36 可选）。
  ///
  /// 只是给用户看的说明，不做强制：插件是声明式包，能力映射到 App 内置函数，
  /// 真要越权得改 App 源码。登记表写清楚、安装前展示出来，比「什么都没写」诚实。
  final List<String> permissions;

  /// 源码仓库 / 更新日志（v1.36 可选）：仅用于「打开看看」，域名见
  /// [allowedLinkHosts]——下载地址的白名单更严，这两个只是展示型链接。
  final String? repoUrl;
  final String? changelogUrl;

  /// 登记项的 7 个必填字段：少一个就丢弃该条（表结构是契约）
  static const Set<String> fieldNames = {
    'id',
    'name',
    'author',
    'version',
    'description',
    'download_url',
    'sha256',
  };

  /// v1.36 新增的**可选**字段：缺省合法（老表照常解析），未知字段仍然拒绝——
  /// 宁可这一条不显示，也不要按客户端自己的理解去猜一个新字段的含义。
  static const Set<String> optionalFieldNames = {
    'category',
    'tags',
    'permissions',
    'repo_url',
    'changelog_url',
  };

  /// 分类上限（表里约定 24 字，够写「题库工具」「学习辅助」这类短标签）
  static const int maxCategoryChars = 24;

  /// 标签：最多 6 个、每个 16 字
  static const int maxTags = 6;
  static const int maxTagChars = 16;

  /// 能力声明：最多 12 条、每条 32 字（对得上 manifest 里的 capabilities）
  static const int maxPermissions = 12;
  static const int maxPermissionChars = 32;

  /// 展示型链接（仓库 / 更新日志）允许的域名。
  ///
  /// 只放行主流代码托管：这两个链接会被「打开浏览器」，不校验就等于让登记表
  /// 决定用户去哪，钓鱼成本太低。
  static const Set<String> allowedLinkHosts = {
    'github.com',
    'gitee.com',
    'gitlab.com',
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
    // 字段集合：必填一个不能少、未知字段一个不能有（防止老客户端「静默误解」
    // 新字段的含义）；v1.36 的可选字段缺失是合法的。
    final keys = map.keys.toSet();
    if (keys.difference(fieldNames).difference(optionalFieldNames).isNotEmpty) {
      return null;
    }
    if (fieldNames.difference(keys).isNotEmpty) return null;

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
      category: _readCategory(map['category']),
      tags: _readStringList(map['tags'],
          maxItems: maxTags, maxChars: maxTagChars),
      permissions: _readStringList(map['permissions'],
          maxItems: maxPermissions, maxChars: maxPermissionChars),
      repoUrl: _readLink(map['repo_url']),
      changelogUrl: _readLink(map['changelog_url']),
    );
  }

  /// 可选字段一律「坏值当缺省」：一个拼错的标签不该让整个插件从表里消失，
  /// 但也不能让它以半截内容混进界面——所以坏的那一项直接忽略。
  static String? _readCategory(Object? raw) {
    if (raw is! String) return null;
    final v = raw.trim();
    if (v.isEmpty || v.length > maxCategoryChars) return null;
    return v;
  }

  static List<String> _readStringList(
    Object? raw, {
    required int maxItems,
    required int maxChars,
  }) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final v = item.trim();
      if (v.isEmpty || v.length > maxChars) continue;
      if (out.contains(v)) continue;
      out.add(v);
      if (out.length >= maxItems) break;
    }
    return List.unmodifiable(out);
  }

  static String? _readLink(Object? raw) {
    if (raw is! String) return null;
    final v = raw.trim();
    final uri = Uri.tryParse(v);
    if (uri == null || uri.scheme != 'https') return null;
    if (!allowedLinkHosts.contains(uri.host)) return null;
    if (uri.path.isEmpty || uri.path == '/') return null;
    return v;
  }

  /// 界面上的分类文案：没写分类统一显示「未分类」，免得各处各写一遍
  String get categoryLabel => category ?? '未分类';

  /// 有仓库或更新日志可以打开
  bool get hasLinks => repoUrl != null || changelogUrl != null;

  /// 搜索命中：id / 名称 / 作者 / 说明 / 分类 / 标签，按小写包含匹配。
  ///
  /// 放在模型里而不是界面里，是为了让「搜什么」这件事有单测兜住。
  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = <String>[
      id,
      name,
      author,
      description,
      category ?? '',
      ...tags,
    ].join('\n').toLowerCase();
    return haystack.contains(q);
  }

  /// 只输出**有值**的可选字段：`toJson().keys` 在最小条目上仍等于
  /// [fieldNames]（老测试与老调用方都靠这个契约）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'author': author,
        'version': version,
        'description': description,
        'download_url': downloadUrl,
        'sha256': sha256,
        if (category != null) 'category': category,
        if (tags.isNotEmpty) 'tags': tags,
        if (permissions.isNotEmpty) 'permissions': permissions,
        if (repoUrl != null) 'repo_url': repoUrl,
        if (changelogUrl != null) 'changelog_url': changelogUrl,
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

/// 本地安装（用户自己下载的 zip）的结果。
///
/// 和 [PluginInstallResult] 分开是因为**没有登记项**可比：没有 [RegistryPlugin]，
/// 也就没有「登记版本 / 可更新」的判断依据，UI 文案不一样。
class PluginLocalInstallResult {
  const PluginLocalInstallResult({
    required this.loaded,
    required this.installedDir,
    required this.updated,
    required this.sourcePath,
    required this.sha256Hex,
  });

  final LoadedPlugin loaded;
  final String installedDir;

  /// true = 覆盖了同 id 的旧版本（保留原来的启停状态）
  final bool updated;

  /// 用户选的那个 zip 的路径（只在本次会话里有意义）
  final String sourcePath;

  /// 本机算出的包哈希：没有登记表可比对，至少留个可回溯的指纹
  final String sha256Hex;
}

/// 拉表 / 安装失败的用户可读错误
class PluginRegistryException implements Exception {
  const PluginRegistryException(this.message, {this.downloadUrl});

  final String message;

  /// 下载全部镜像都失败时保留**原始**下载地址：UI 可以复制给用户，
  /// 让用户用浏览器下载后用「本地安装」导入。
  final String? downloadUrl;

  @override
  String toString() => message;
}

/// 拉表 / 校验 / 安装。文件层与数据库层都在这里，UI 只负责确认与展示。
class PluginRegistryService {
  PluginRegistryService._();

  static final PluginRegistryService instance = PluginRegistryService._();

  /// 登记表地址（客户端唯一读的地址；镜像只是它的加速，不改变「以 GitHub 为准」）
  static const String registryUrl = SmartHttpClient.registryRawUrl;

  /// 「已看过 disclaimer」的标记键：只认一次，之后安装不再反复弹
  static const String disclaimerAckKey = 'plugin_registry_disclaimer_ack_v1';

  /// 单个源的超时（v1.36：8 秒换下一个源，见 [SmartHttpClient]）
  static const Duration defaultTimeout = SmartHttpClient.defaultTimeout;

  /// 插件包单源下载超时：包比 JSON 大，给宽一点
  static const Duration defaultDownloadTimeout =
      SmartHttpClient.defaultDownloadTimeout;

  final DatabaseService _db = DatabaseService.instance;

  /// 拉表。任何失败都抛 [PluginRegistryException]：
  /// 调用方据此提示「本次没拉到」，但**保留上一次成功的列表**。
  ///
  /// v1.36：不传 [url] 时走多源回退（原始 → jsDelivr → 4 个加速），
  /// 传了 [url] 就只试那一个（开发者 / 测试用的确定行为）。
  /// [customMirror] 缺省取 [SmartHttpClient.instance] 里的用户配置。
  Future<RegistrySnapshot> fetch({
    String? url,
    http.Client? client,
    Duration timeout = defaultTimeout,
    String? customMirror,
  }) async {
    final smart = SmartHttpClient(
      client: client,
      customMirror: customMirror ?? SmartHttpClient.instance.customMirror,
    );
    try {
      final result = url == null
          ? await smart.fetchRegistry(timeout: timeout)
          : await smart.getFirst(
              [SmartSource('指定地址', url)],
              timeout: timeout,
              headers: SmartHttpClient.jsonHeaders,
              originalUrl: url,
              failurePrefix: '插件表读取失败',
              validate: SmartHttpClient.looksLikeJson,
            );
      return RegistrySnapshot.parse(result.text);
    } on SmartHttpException catch (e) {
      throw PluginRegistryException(e.message);
    } on FormatException catch (e) {
      throw PluginRegistryException('插件表格式异常：${e.message}');
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

  /// 插件 id 要直接当目录名用：挡掉空 id、路径分隔符和 `..`。
  ///
  /// 与登记表的 id 规则一致（[RegistryPlugin]），但这里**必须**再挡一次：
  /// 本地安装没有登记表把关，zip 里的 manifest 完全由作者决定，
  /// `id: "../../etc"` 这种就是标准的 zip-slip 入口。
  static final RegExp _safeIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{2,63}$');

  static bool isSafePluginId(String id) => _safeIdPattern.hasMatch(id.trim());

  /// 只读清单、不安装：给「从本地文件安装」的确认弹窗用。
  ///
  /// 解到临时目录读取 `plugin.json` / `manifest.json`，读完即删——
  /// 用户点「取消」不会在插件目录里留任何东西。
  Future<PluginManifest> inspectZip(String zipPath) async {
    final staging = Directory.systemTemp.createTempSync('natsume_plugin_inspect_');
    try {
      final loaded = await PluginLoader.loadFromZip(zipPath, staging.path);
      return loaded.manifest;
    } catch (e) {
      throw PluginRegistryException('插件包无法解析：$e');
    } finally {
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 本地安装（v1.36）：用户在浏览器里手动下好 zip 之后走这里。
  ///
  /// 什么时候用：登记表的所有下载源都被墙 / 全部给坏包时，UI 让用户复制
  /// 「原始下载地址」用浏览器下载，再用这个入口装上。另一条路是世界总览的
  /// 「导入插件」——两者最终落到同一个目录、同一条 `plugins` 表记录。
  ///
  /// 与 [install] 的差别只有一处：**没有登记表可比对**。没有 sha256 参照，
  /// 只能把本机算出的哈希记进清单（`local.sha256`），并在 UI 上让用户
  /// 先看清单摘要再确认。其余流程完全一致：解到 staging → 校验 id →
  /// 原子替换 → 登记入库（覆盖安装保留原启停状态）。
  Future<PluginLocalInstallResult> installFromZip(
    String zipPath, {
    String? sourceLabel,
  }) async {
    final file = File(zipPath);
    if (!file.existsSync()) {
      throw const PluginRegistryException('插件包不存在（可能已被移动或删除）');
    }
    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } catch (e) {
      throw PluginRegistryException('读取插件包失败：$e');
    }

    final root = await pluginRoot();
    Directory? staging;
    try {
      staging = Directory.systemTemp.createTempSync('natsume_plugin_local_');
      final staged = Directory(p.join(staging.path, 'unpacked'));
      final loaded = await PluginLoader.loadFromZip(zipPath, staged.path);
      final id = loaded.manifest.id.trim();
      if (!isSafePluginId(id)) {
        throw PluginRegistryException(
            '插件包 id（${id.isEmpty ? '空' : id}）不能用作目录名，已拒绝安装');
      }

      final installDir = Directory(p.join(root.path, id));
      final existing = await _db.getPlugin(id);
      if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      _copyDirectory(staged, installDir);

      final digest = sha256Hex(bytes);
      final manifest = <String, dynamic>{
        ...loaded.manifest.toJson(),
        // 来源信息随清单落库：日后「这个插件哪来的、装的是哪个包」可查
        'local': {
          'file': p.basename(zipPath),
          'sha256': digest,
          'source': sourceLabel ?? 'manual',
          'installed_at': DateTime.now().toIso8601String(),
        },
      };
      await _db.upsertPlugin(PluginInfo(
        id: id,
        name: loaded.manifest.name.isNotEmpty ? loaded.manifest.name : id,
        version: loaded.manifest.version,
        author: loaded.manifest.author,
        description: loaded.manifest.description,
        manifest: jsonEncode(manifest),
        enabled: existing?.enabled ?? true,
        installedAt: existing?.installedAt ?? DateTime.now().toIso8601String(),
      ));
      return PluginLocalInstallResult(
        loaded: loaded,
        installedDir: installDir.path,
        updated: existing != null,
        sourcePath: zipPath,
        sha256Hex: digest,
      );
    } on PluginRegistryException {
      rethrow;
    } catch (e) {
      throw PluginRegistryException('安装失败：$e');
    } finally {
      if (staging != null && staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
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
  ///
  /// v1.36：下载走 [SmartHttpClient]，逐个镜像尝试；每个镜像的响应都先算
  /// sha256，不匹配就丢弃该镜像继续下一个，绝不会先落盘再校验。
  Future<PluginInstallResult> install(
    RegistryPlugin entry, {
    http.Client? client,
    Duration timeout = defaultDownloadTimeout,
    String? customMirror,
  }) async {
    final smart = SmartHttpClient(
      client: client,
      customMirror: customMirror ?? SmartHttpClient.instance.customMirror,
    );
    final root = await pluginRoot();
    final installDir = Directory(p.join(root.path, entry.id));
    Directory? staging;
    try {
      final SmartHttpResult download;
      try {
        download = await smart.downloadVerified(
          url: entry.downloadUrl,
          expectedSha256: entry.sha256,
          timeout: timeout,
        );
      } on SmartHttpException catch (e) {
        // 带上原始地址：全部镜像失败时，UI 可以让用户复制后用浏览器下载
        throw PluginRegistryException(e.message, downloadUrl: entry.downloadUrl);
      }
      final bytes = download.bytes;

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
          // v1.36：记下实际命中的源，排查「镜像给了个坏包」时有据可查
          'source': download.label,
          'source_url': download.url,
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
    } on PluginRegistryException {
      rethrow;
    } catch (e) {
      throw PluginRegistryException('安装失败：$e');
    } finally {
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
