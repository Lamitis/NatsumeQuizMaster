import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';

import '../../models/bank_category.dart';
import '../../models/knowledge_base.dart';
import '../../models/plugin.dart';
import '../../models/question_bank.dart';
import '../../models/world.dart';
import '../../utils/natsume_personality.dart';
import '../bank_file_service.dart';
import '../database_service.dart';
import '../knowledge_base/kb_file_service.dart';
import 'plugin_loader.dart';

/// 世界导入结果。
class WorldImportResult {
  final WorldInfo world;
  final int kbCount;
  final int bankCount;
  final int pluginCount;

  /// 分类导出包（`type=category_export`）才有值
  final bool isCategoryExport;
  final String? categoryName;
  final int? categoryId;

  /// 因 uid / 内容签名命中而被跳过的重复成员数（v1.41.2）
  final int skippedCount;

  const WorldImportResult(
    this.world,
    this.kbCount,
    this.bankCount,
    this.pluginCount, {
    this.isCategoryExport = false,
    this.categoryName,
    this.categoryId,
    this.skippedCount = 0,
  });
}

/// 世界打包/解包（v13 · world-overview）。
///
/// 「世界」= 知识库 + 题库 + 插件 的打包单元（`.natsume-world`，本质是 zip）。
/// 导出：把各成员以各自标准格式（知识库走 [KbFileService]、题库走
/// [BankFileService]、插件走 [PluginLoader]）写入临时目录，再打成 zip；
/// 导入：解包后依次导入，并登记一条 [WorldInfo]。
class WorldService {
  WorldService._();

  static final DatabaseService _db = DatabaseService.instance;

  static const String formatMarker = 'natsume-world';

  /// 导出世界。成员为空也允许（仅打包插件或仅打包题库）。
  /// 返回目标文件路径；失败返回 null。
  static Future<String?> exportWorld({
    required String worldId,
    required String worldName,
    required List<int> kbIds,
    required List<int> bankIds,
    required List<String> pluginIds,
    required String destPath,
  }) async {
    final tmp = Directory.systemTemp.createTempSync('natsume_world_');
    try {
      final manifest = {
        'format': formatMarker,
        'id': worldId,
        'name': worldName,
        'version': '1',
        // 静默写入专属 creator 标识（世界包的专属烙印）
        'creator': NatsumePersonality.creatorMark,
        'kb_ids': kbIds,
        'bank_ids': bankIds,
        'plugin_ids': pluginIds,
      };
      File('${tmp.path}/world.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
      Directory('${tmp.path}/kb').createSync(recursive: true);
      Directory('${tmp.path}/banks').createSync(recursive: true);
      Directory('${tmp.path}/plugins').createSync(recursive: true);

      // 知识库成员
      for (final kbId in kbIds) {
        final p = await KbFileService.exportKnowledgeBase(
            kbId, '${tmp.path}/kb/$kbId.json');
        if (p == null) continue; // 空库跳过
      }

      // 题库成员
      final banks = await _db.getAllBanks();
      for (final bankId in bankIds) {
        final bank = banks.where((b) => b.id == bankId).firstOrNull;
        if (bank == null) continue;
        await BankFileService.exportBank(
            bankId, bank.name, '${tmp.path}/banks/$bankId.json');
      }

      // 插件成员：写出 plugin.json 清单
      final plugins = await _db.getAllPlugins();
      for (final pid in pluginIds) {
        final p = plugins.where((x) => x.id == pid).firstOrNull;
        if (p == null) continue;
        final dir = Directory('${tmp.path}/plugins/$pid');
        dir.createSync(recursive: true);
        final raw = _safeJson(p.manifest);
        final m = PluginManifest.fromJson(raw);
        File('${dir.path}/plugin.json')
            .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(m.toJson()));
      }

      final encoder = ZipEncoder();
      final archive = Archive();
      await for (final e in tmp.list(recursive: true)) {
        if (e is! File) continue;
        // Windows 路径分隔符归一为 '/'，保证 zip 内条目名跨平台一致
        final rel = e.path
            .substring(tmp.path.length)
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        archive.addFile(
            ArchiveFile(rel, e.lengthSync(), e.readAsBytesSync()));
      }
      final out = File(destPath);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(encoder.encode(archive)!);
      return out.path;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 分类级导出（v1.39.3）：把一个分类及其子分类下的题库 / 知识库打成
  /// 特殊世界包。`world.json` 的 `type=category_export`，并带分类路径与树。
  ///
  /// [includeBanks]/[includeKbs] 让题库页与知识库页各自只导自己那一类；
  /// 分类树本身始终完整写出（空分类也会保留结构）。
  static Future<String?> exportCategory({
    required int categoryId,
    required String destPath,
    bool includeBanks = true,
    bool includeKbs = true,
  }) async {
    final cats = await _db.getAllBankCategories();
    final root = cats.where((c) => c.id == categoryId).firstOrNull;
    if (root == null) return null;
    final childrenOf = <int?, List<BankCategory>>{};
    for (final c in cats) {
      childrenOf.putIfAbsent(c.parentId, () => []).add(c);
    }
    final subtree = <int>{};
    void walk(BankCategory c) {
      if (c.id == null) return;
      subtree.add(c.id!);
      for (final child in childrenOf[c.id] ?? const <BankCategory>[]) {
        walk(child);
      }
    }

    walk(root);

    final banks = includeBanks
        ? (await _db.getAllBanks())
            .where((b) => subtree.contains(b.categoryId))
            .toList()
        : <QuestionBank>[];
    final kbs = includeKbs
        ? (await _db.getAllKnowledgeBases())
            .where((k) => subtree.contains(k.categoryId))
            .toList()
        : <KnowledgeBase>[];

    final parentOf = {for (final c in cats) c.id: c.parentId};
    final path = <String>[];
    BankCategory? cursor = root;
    final guard = <int>{};
    while (cursor != null && cursor.id != null && guard.add(cursor.id!)) {
      path.insert(0, cursor.name);
      final parentId = parentOf[cursor.id];
      cursor = parentId == null
          ? null
          : cats.where((c) => c.id == parentId).firstOrNull;
    }

    final tmp = Directory.systemTemp.createTempSync('natsume_world_');
    try {
      final manifest = {
        'format': formatMarker,
        'type': 'category_export',
        'id': const Uuid().v4(),
        'name': root.name,
        'version': '1',
        'creator': NatsumePersonality.creatorMark,
        'category_name': root.name,
        'category_path': path,
        'category_tree':
            _categoryNodeJson(root, childrenOf, banks, kbs),
        'bank_ids': [for (final b in banks) b.id],
        'kb_ids': [for (final k in kbs) k.id],
        'plugin_ids': const <String>[],
      };
      File('${tmp.path}/world.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
      Directory('${tmp.path}/kb').createSync(recursive: true);
      Directory('${tmp.path}/banks').createSync(recursive: true);

      for (final kb in kbs) {
        if (kb.id == null) continue;
        await KbFileService.exportKnowledgeBase(
            kb.id!, '${tmp.path}/kb/${kb.id}.json');
      }
      for (final bank in banks) {
        if (bank.id == null) continue;
        await BankFileService.exportBank(
            bank.id!, bank.name, '${tmp.path}/banks/${bank.id}.json');
      }

      final encoder = ZipEncoder();
      final archive = Archive();
      await for (final e in tmp.list(recursive: true)) {
        if (e is! File) continue;
        final rel = e.path
            .substring(tmp.path.length)
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        archive.addFile(
            ArchiveFile(rel, e.lengthSync(), e.readAsBytesSync()));
      }
      final out = File(destPath);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(encoder.encode(archive)!);
      return out.path;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 分类树节点：只存名字 + 成员文件名，导入端按节点创建分类并挂载。
  static Map<String, dynamic> _categoryNodeJson(
    BankCategory node,
    Map<int?, List<BankCategory>> childrenOf,
    List<QuestionBank> banks,
    List<KnowledgeBase> kbs,
  ) {
    final id = node.id;
    return {
      'name': node.name,
      'banks': [
        for (final b in banks)
          if (b.categoryId == id) '${b.id}.json',
      ],
      'kbs': [
        for (final k in kbs)
          if (k.categoryId == id) '${k.id}.json',
      ],
      'children': [
        for (final child in childrenOf[id] ?? const <BankCategory>[])
          _categoryNodeJson(child, childrenOf, banks, kbs),
      ],
    };
  }


  /// 导入世界。返回导入统计；解包失败抛异常（由调用方转用户提示）。
  ///
  /// 分类导出包会先按 `category_tree` 建/复用分类，再把每个题库 / 知识库
  /// 挂到对应节点；普通世界包保持原行为（不加分类）。
  static Future<WorldImportResult> importWorld(String zipPath) async {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final tmp = Directory.systemTemp.createTempSync('natsume_world_import_');
    try {
      for (final f in archive) {
        if (!f.isFile) continue;
        // 防路径穿越：拒绝含 .. 或绝对路径的条目
        if (f.name.contains('..') || f.name.startsWith('/')) continue;
        final dest = File('${tmp.path}/${f.name}');
        dest.parent.createSync(recursive: true);
        dest.writeAsBytesSync(f.content as List<int>);
      }

      final manifestFile = File('${tmp.path}/world.json');
      if (!manifestFile.existsSync()) throw Exception('世界包缺少 world.json');
      final manifest = jsonDecode(manifestFile.readAsStringSync());
      if (manifest is! Map || manifest['format'] != formatMarker) {
        throw Exception('不是NatsumeQuizMaster世界文件（缺少 format 标记）');
      }

      final isCategory = manifest['type'] == 'category_export';
      var kbCount = 0;
      var bankCount = 0;
      var pluginCount = 0;
      var skippedCount = 0;
      String? categoryName;
      int? categoryId;

      if (isCategory) {
        final rawPath = manifest['category_path'];
        final path = rawPath is List
            ? rawPath.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
            : <String>[];
        final fallbackName =
            (manifest['category_name'] ?? manifest['name'] ?? '导入分类').toString();
        final rootName = path.isNotEmpty ? path.last : fallbackName;
        int? parentId;
        for (final name in path.take(path.length > 0 ? path.length - 1 : 0)) {
          parentId = await _ensureCategory(name, parentId);
        }
        final rootId = await _ensureCategory(rootName, parentId);
        categoryName = rootName;
        categoryId = rootId;

        final tree = manifest['category_tree'];
        final existingNames =
            (await _db.getAllBanks()).map((b) => b.name).toSet();
        if (tree is Map) {
          final counts = await _importCategoryNode(
            Map<String, dynamic>.from(tree),
            rootId,
            tmp,
            existingNames,
          );
          bankCount += counts.$1;
          kbCount += counts.$2;
          skippedCount += counts.$3;
        } else {
          final counts = await _importFlatIntoCategory(
              rootId, tmp, existingNames);
          bankCount += counts.$1;
          kbCount += counts.$2;
          skippedCount += counts.$3;
        }
      } else {
        final kbDir = Directory('${tmp.path}/kb');
        if (kbDir.existsSync()) {
          await for (final e in kbDir.list()) {
            if (e is File && e.path.endsWith('.json')) {
              final r = await KbFileService.importKbFile(e.path);
              if (r.$1 > 0) {
                kbCount++;
              } else if (r.$2?.contains('已跳过') == true) {
                skippedCount++;
              }
            }
          }
        }

        final bankDir = Directory('${tmp.path}/banks');
        if (bankDir.existsSync()) {
          await for (final e in bankDir.list()) {
            if (e is File && e.path.endsWith('.json')) {
              final r = await BankFileService.importBankFile(e.path);
              bankCount += r.bankCount;
              skippedCount += r.skippedCount;
            }
          }
        }
      }

      final pluginDir = Directory('${tmp.path}/plugins');
      if (pluginDir.existsSync()) {
        await for (final e in pluginDir.list()) {
          if (e is! Directory) continue;
          final loaded = await PluginLoader.loadFromDirectory(e.path);
          await _db.upsertPlugin(PluginInfo(
            id: loaded.manifest.id,
            name: loaded.manifest.name,
            version: loaded.manifest.version,
            author: loaded.manifest.author,
            description: loaded.manifest.description,
            manifest: jsonEncode(loaded.manifest.toJson()),
            installedAt: DateTime.now().toIso8601String(),
          ));
          pluginCount++;
        }
      }

      final world = WorldInfo(
        id: (manifest['id'] ?? const Uuid().v4()).toString(),
        name: isCategory
            ? (categoryName ?? (manifest['name'] ?? '导入分类').toString())
            : (manifest['name'] ?? '导入世界').toString(),
        version: (manifest['version'] ?? '1').toString(),
        manifest: jsonEncode(manifest),
        installedAt: DateTime.now().toIso8601String(),
      );
      await _db.upsertWorld(world);
      return WorldImportResult(
        world,
        kbCount,
        bankCount,
        pluginCount,
        isCategoryExport: isCategory,
        categoryName: categoryName,
        categoryId: categoryId,
        skippedCount: skippedCount,
      );
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 按名字+父级复用/创建分类；同名同级自动合并（任务允许的「合并」策略）。
  static Future<int> _ensureCategory(String name, int? parentId) async {
    final all = await _db.getAllBankCategories();
    final existing = all
        .where((c) => c.name == name && c.parentId == parentId)
        .firstOrNull;
    if (existing?.id != null) return existing!.id!;
    return _db.insertBankCategory(name: name, parentId: parentId);
  }

  /// 递归导入分类树节点：每个节点的题库/知识库都挂到该节点分类下。
  static Future<(int, int, int)> _importCategoryNode(
    Map<String, dynamic> node,
    int categoryId,
    Directory tmp,
    Set<String> existingNames,
  ) async {
    var bankCount = 0;
    var kbCount = 0;
    var skippedCount = 0;
    final bankFiles = node['banks'];
    if (bankFiles is List) {
      for (final raw in bankFiles) {
        final name = raw.toString();
        if (name.contains('..') || name.startsWith('/')) continue;
        final file = File('${tmp.path}/banks/$name');
        if (!await file.exists()) continue;
        final r = await BankFileService.importBankFile(
          file.path,
          existingNames: existingNames,
          categoryId: categoryId,
        );
        bankCount += r.bankCount;
        skippedCount += r.skippedCount;
      }
    }
    final kbFiles = node['kbs'];
    if (kbFiles is List) {
      for (final raw in kbFiles) {
        final name = raw.toString();
        if (name.contains('..') || name.startsWith('/')) continue;
        final file = File('${tmp.path}/kb/$name');
        if (!await file.exists()) continue;
        final r = await KbFileService.importKbFile(
          file.path,
          categoryId: categoryId,
        );
        if (r.$1 > 0) {
          kbCount++;
        } else if (r.$2?.contains('已跳过') == true) {
          skippedCount++;
        }
      }
    }
    final children = node['children'];
    if (children is List) {
      for (final child in children) {
        if (child is! Map) continue;
        final childName = (child['name'] ?? '').toString().trim();
        if (childName.isEmpty) continue;
        final childId = await _ensureCategory(childName, categoryId);
        final counts = await _importCategoryNode(
          Map<String, dynamic>.from(child),
          childId,
          tmp,
          existingNames,
        );
        bankCount += counts.$1;
        kbCount += counts.$2;
        skippedCount += counts.$3;
      }
    }
    return (bankCount, kbCount, skippedCount);
  }

  /// 分类树缺失时的兼容路径：把包里的成员全部塞进根分类。
  static Future<(int, int, int)> _importFlatIntoCategory(
    int categoryId,
    Directory tmp,
    Set<String> existingNames,
  ) async {
    var bankCount = 0;
    var kbCount = 0;
    var skippedCount = 0;
    final bankDir = Directory('${tmp.path}/banks');
    if (bankDir.existsSync()) {
      await for (final e in bankDir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final r = await BankFileService.importBankFile(
          e.path,
          existingNames: existingNames,
          categoryId: categoryId,
        );
        bankCount += r.bankCount;
        skippedCount += r.skippedCount;
      }
    }
    final kbDir = Directory('${tmp.path}/kb');
    if (kbDir.existsSync()) {
      await for (final e in kbDir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final r = await KbFileService.importKbFile(e.path, categoryId: categoryId);
        if (r.$1 > 0) {
          kbCount++;
        } else if (r.$2?.contains('已跳过') == true) {
          skippedCount++;
        }
      }
    }
    return (bankCount, kbCount, skippedCount);
  }

  static Map<String, dynamic> _safeJson(String raw) {
    try {
      final d = jsonDecode(raw);
      return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
