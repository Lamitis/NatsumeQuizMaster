import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';

import '../../models/plugin.dart';
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

  const WorldImportResult(
      this.world, this.kbCount, this.bankCount, this.pluginCount);
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

  /// 导入世界。返回导入统计；解包失败抛异常（由调用方转用户提示）。
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

      var kbCount = 0;
      var bankCount = 0;
      var pluginCount = 0;

      final kbDir = Directory('${tmp.path}/kb');
      if (kbDir.existsSync()) {
        await for (final e in kbDir.list()) {
          if (e is File && e.path.endsWith('.json')) {
            final r = await KbFileService.importKbFile(e.path);
            if (r.$1 > 0) kbCount++;
          }
        }
      }

      final bankDir = Directory('${tmp.path}/banks');
      if (bankDir.existsSync()) {
        await for (final e in bankDir.list()) {
          if (e is File && e.path.endsWith('.json')) {
            final r = await BankFileService.importJsonFile(e.path);
            if (r.$1 > 0) bankCount++;
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
        name: (manifest['name'] ?? '导入世界').toString(),
        version: (manifest['version'] ?? '1').toString(),
        manifest: jsonEncode(manifest),
        installedAt: DateTime.now().toIso8601String(),
      );
      await _db.upsertWorld(world);
      return WorldImportResult(world, kbCount, bankCount, pluginCount);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
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
