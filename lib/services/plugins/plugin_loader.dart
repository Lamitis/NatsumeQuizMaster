import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

/// 插件清单（`plugin.json`）。
///
/// 插件是**声明式包**：清单 + 可选资产（提示词、内置知识库、示例题库），
/// 能力映射到 App 内置函数，**不执行任意第三方代码**。
class PluginManifest {
  final String id;
  final String name;
  final String version;
  final String? author;
  final String? description;
  final List<String> capabilities;
  final Map<String, dynamic> raw;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.author,
    this.description,
    this.capabilities = const [],
    this.raw = const {},
  });

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'];
    return PluginManifest(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      version: (json['version'] ?? '0.0.1').toString(),
      author: json['author']?.toString(),
      description: json['description']?.toString(),
      capabilities: caps is List ? caps.map((e) => e.toString()).toList() : const [],
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        if (author != null) 'author': author,
        if (description != null) 'description': description,
        'capabilities': capabilities,
      };
}

/// 加载后的插件：清单 + 提示词 + 资产文本（相对路径 → 内容）。
class LoadedPlugin {
  final PluginManifest manifest;
  final String? prompt;
  final Map<String, String> assets;
  final String installedDir;

  const LoadedPlugin({
    required this.manifest,
    this.prompt,
    this.assets = const {},
    required this.installedDir,
  });
}

/// 插件的提示词资产：`prompt.md`（系统提示词）+ `prompts/*.md`（功能模板）。
///
/// 与 [LoadedPlugin] 的区别是**只含提示词**：不读 `kb/`、示例题库等大资产，
/// 供 AI 请求前的轻量刷新使用（见 [PluginLoader.loadPrompts]）。
class PluginPrompts {
  final PluginManifest manifest;

  /// `prompt.md` 原文；没有该文件时为 null
  final String? prompt;

  /// 功能模板：键是 `/` 分隔的相对路径（如 `prompts/cheat_sheet.md`）
  final Map<String, String> templates;

  const PluginPrompts({
    required this.manifest,
    this.prompt,
    this.templates = const {},
  });

  bool get isEmpty => (prompt ?? '').trim().isEmpty && templates.isEmpty;
}

/// 插件加载器（v13 · world-overview）。
///
/// 从 zip 包或目录加载插件：解析 `plugin.json`，读取可选 `prompt.md` 与
/// `kb/`、`sample_bank.json` 等资产。安装目录用于把插件资产落到 App 私有
/// 存储，供知识库导入 / 示例题库导入引用。
class PluginLoader {
  const PluginLoader._();

  static const String manifestFileName = 'plugin.json';

  /// 清单文件名的兼容别名（见根目录 `PLUGIN_DEVELOPMENT.md`）。
  ///
  /// 早期实现只认 `plugin.json`，而对外文档与社区习惯多写 `manifest.json`。
  /// 现在两个名字等价：先找 `plugin.json`，找不到再找 `manifest.json`——
  /// 老插件包不用改，新插件包按文档写 `manifest.json` 也能装。
  static const String manifestAliasFileName = 'manifest.json';

  /// 清单候选（顺序即优先级）
  static const List<String> manifestCandidates = [
    manifestFileName,
    manifestAliasFileName,
  ];

  static Future<LoadedPlugin> loadFromZip(
      String zipPath, String installDir) async {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, List<int>>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      // 防路径穿越：拒绝含 .. 或绝对路径的条目
      if (f.name.contains('..') || f.name.startsWith('/')) continue;
      files[f.name] = f.content as List<int>;
    }
    final manifest = _readManifestFromMap(files);
    if (manifest == null) throw Exception('插件包缺少有效的 plugin.json');

    // 资产落盘到安装目录
    final dir = Directory(installDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final entry in files.entries) {
      final dest = File('$installDir/${entry.key}');
      dest.parent.createSync(recursive: true);
      dest.writeAsBytesSync(entry.value);
    }
    return _assemble(manifest, files, installDir);
  }

  static Future<LoadedPlugin> loadFromDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) throw Exception('插件目录不存在');
    final files = <String, List<int>>{};
    await for (final e in dir.list(recursive: true)) {
      if (e is File) {
        // Windows 路径分隔符归一为 '/'，与 zip 内条目名保持一致
        final rel = e.path
            .substring(dir.path.length)
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        files[rel] = await e.readAsBytes();
      }
    }
    final manifest = _readManifestFromMap(files);
    if (manifest == null) throw Exception('插件目录缺少有效的 plugin.json');
    return _assemble(manifest, files, dirPath);
  }

  /// 单次读取的提示词文件上限（256KB）。
  ///
  /// 提示词最终是拼进模型请求的，几百 KB 的「提示词」纯属病态输入——既烧
  /// Token 又撞上下文上限，直接跳过比让请求 400 更好。
  static const int maxPromptBytes = 256 * 1024;

  /// 只读**提示词相关**文件：`prompt.md` + `prompts/*.md`（v1.37）。
  ///
  /// 为什么单独一个入口：安装目录里的 `kb/` 可能有几十 MB 文档，
  /// [loadFromDirectory] 会把所有文本资产读进内存；AI 每次请求前刷新提示词
  /// 没必要付这个代价。清单无效（缺 `plugin.json` / 不是合法 JSON）时返回
  /// null，由调用方跳过该目录。
  static Future<PluginPrompts?> loadPrompts(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    List<int>? manifestBytes;
    for (final name in manifestCandidates) {
      final candidate = File('${dir.path}/$name');
      if (candidate.existsSync()) {
        manifestBytes = await candidate.readAsBytes();
        break;
      }
    }
    if (manifestBytes == null) return null;

    final PluginManifest manifest;
    try {
      final json = jsonDecode(utf8.decode(manifestBytes));
      if (json is! Map) return null;
      manifest = PluginManifest.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }

    Future<String?> readText(File file) async {
      try {
        if (!file.existsSync()) return null;
        if (file.lengthSync() > maxPromptBytes) return null;
        return await file.readAsString();
      } catch (_) {
        // 非 UTF-8 / 读取失败：当这个文件不存在，不拖垮整次刷新
        return null;
      }
    }

    final prompt = await readText(File('${dir.path}/prompt.md'));
    final templates = <String, String>{};
    final promptsDir = Directory('${dir.path}/prompts');
    if (promptsDir.existsSync()) {
      final files = promptsDir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final lower = file.path.toLowerCase();
        if (!lower.endsWith('.md') &&
            !lower.endsWith('.markdown') &&
            !lower.endsWith('.txt')) {
          continue;
        }
        final text = await readText(file);
        if (text == null || text.trim().isEmpty) continue;
        // 键统一成 '/' 分隔的相对路径（与 [LoadedPlugin.assets] 同口径）
        final name = file.path
            .substring(promptsDir.path.length)
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        templates['prompts/$name'] = text;
      }
    }

    return PluginPrompts(
      manifest: manifest,
      prompt: prompt,
      templates: templates,
    );
  }

  static PluginManifest? _readManifestFromMap(Map<String, List<int>> files) {
    List<int>? bytes;
    for (final name in manifestCandidates) {
      final candidate = files[name];
      if (candidate != null) {
        bytes = candidate;
        break;
      }
    }
    if (bytes == null) return null;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      return json is Map ? PluginManifest.fromJson(Map<String, dynamic>.from(json)) : null;
    } catch (_) {
      return null;
    }
  }

  static LoadedPlugin _assemble(
      PluginManifest manifest, Map<String, List<int>> files, String dir) {
    final promptBytes = files['prompt.md'];
    final assets = <String, String>{};
    for (final entry in files.entries) {
      final name = entry.key;
      if (manifestCandidates.contains(name) || name == 'prompt.md') continue;
      // 只把文本类资产读入内存（kb 文档、示例题库）；二进制忽略
      final lower = name.toLowerCase();
      if (lower.endsWith('.md') ||
          lower.endsWith('.txt') ||
          lower.endsWith('.json')) {
        try {
          assets[name] = utf8.decode(entry.value);
        } catch (_) {}
      }
    }
    return LoadedPlugin(
      manifest: manifest,
      prompt: promptBytes == null ? null : utf8.decode(promptBytes),
      assets: assets,
      installedDir: dir,
    );
  }
}
