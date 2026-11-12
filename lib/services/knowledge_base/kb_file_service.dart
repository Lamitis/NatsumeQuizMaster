import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../../models/kb_chunk.dart';
import '../../models/kb_document.dart';
import '../../models/knowledge_base.dart';
import '../../utils/natsume_personality.dart';
import '../database_service.dart';
import 'kb_chunker.dart';

/// 知识库包导出结果（`.natsume-kb`：一个 zip 里装多个知识库）。
class KbBundleExportResult {
  /// 生成好的包路径；没有可导出内容时为 null
  final String? path;

  /// 真正写进包里的知识库数
  final int kbCount;

  /// 没有文档而跳过的知识库数
  final int skippedCount;

  const KbBundleExportResult({
    this.path,
    this.kbCount = 0,
    this.skippedCount = 0,
  });

  bool get saved => path != null;
}

/// 知识库包导入结果。
class KbBundleImportResult {
  /// 新建的知识库数
  final int kbCount;

  /// 因 uid / 内容命中而被跳过的知识库数
  final int skippedCount;

  /// 失败原因（成功或「全部已存在」时为 null）
  final String? error;

  const KbBundleImportResult({
    this.kbCount = 0,
    this.skippedCount = 0,
    this.error,
  });

  bool get ok => error == null;
}

/// 知识库导出/导入（v13）。
///
/// 格式仿 `BankFileService`：单 JSON 文件，带 `format` 标记 + 知识库名 +
/// 文档列表（含解析后的全文 `content`，可被导入直接切块入库，闭环往返）。
/// 导入时按文档名去重建库（不覆盖已有知识库，重名自动编号由调用方处理）。
class KbFileService {
  KbFileService._();

  static final DatabaseService _db = DatabaseService.instance;

  static const String formatMarker = 'natsume-knowledge-base';

  /// 多知识库包（`.natsume-kb`，本质是 zip）的清单格式标记
  static const String bundleFormatMarker = 'natsume-kb-bundle';

  /// 多知识库包的推荐扩展名
  static const String bundleExtension = '.natsume-kb';

  /// 包内清单文件名
  static const String bundleManifestName = 'kb.json';

  static Future<KnowledgeBase?> _getKb(int kbId) async {
    final all = await _db.getAllKnowledgeBases();
    for (final kb in all) {
      if (kb.id == kbId) return kb;
    }
    return null;
  }

  /// 解析 JSON 文件 → (知识库, 文档列表, 错误信息)。
  static Future<(KnowledgeBase?, List<KbDocument>, String?)> parseKbFile(
      String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return (null, const <KbDocument>[], '文件不存在: $filePath');
    }
    final String raw;
    try {
      raw = await file.readAsString();
    } catch (e) {
      return (null, const <KbDocument>[], '读取文件失败: $e');
    }
    final dynamic data;
    try {
      data = jsonDecode(raw);
    } catch (e) {
      return (null, const <KbDocument>[], '不是有效的 JSON 文件: $e');
    }
    if (data is! Map || data['format'] != formatMarker) {
      return (null, const <KbDocument>[], '不是NatsumeQuizMaster知识库文件（缺少 format 标记）');
    }
    final docsRaw = data['documents'];
    if (docsRaw is! List || docsRaw.isEmpty) {
      return (null, const <KbDocument>[], '知识库文件中没有有效文档');
    }
    final now = DateTime.now().toIso8601String();
    final docs = <KbDocument>[];
    for (final item in docsRaw) {
      if (item is! Map) continue;
      final content = (item['content'] ?? '').toString();
      if (content.trim().isEmpty) continue;
      docs.add(KbDocument(
        kbId: 0, // 导入时由调用方设置
        name: (item['name'] ?? '未命名文档').toString(),
        source: item['source']?.toString(),
        fileExt: item['file_ext']?.toString(),
        content: content,
        createdAt: now,
      ));
    }
    if (docs.isEmpty) return (null, const <KbDocument>[], '知识库文件中没有有效文档');
    final uidRaw = data['uid']?.toString().trim();
    return (
      KnowledgeBase(
        name: (data['name'] ?? '导入知识库').toString(),
        description: data['description']?.toString(),
        uid: (uidRaw == null || uidRaw.isEmpty) ? null : uidRaw,
        createdAt: now,
      ),
      docs,
      null,
    );
  }

  /// 文档内容指纹（**不含知识库名**）：与文档顺序无关。
  static String _docsFingerprint(List<KbDocument> docs) {
    final parts = docs
        .map((d) => '${d.name.trim()}\u0001${d.content.trim()}')
        .toList()
      ..sort();
    return parts.join('\u0003');
  }

  /// 知识库内容签名：知识库名 + 文档集合。
  ///
  /// 旧版导出文件没有 uid，用内容签名兜底去重（v1.41.2）。
  static String contentSignature(String name, List<KbDocument> docs) => sha1
      .convert(utf8.encode('$name\u0000${_docsFingerprint(docs)}'))
      .toString();

  /// 只按文档内容取签名（忽略知识库名，v1.41.4）。
  ///
  /// 去重不能带名字：被改名过（自动编号 / 用户手动改）的同一份知识库，
  /// 带名字的签名永远对不上，每导一次就会多一份。
  static String documentsSignature(List<KbDocument> docs) =>
      sha1.convert(utf8.encode(_docsFingerprint(docs))).toString();

  /// `X` / `X(2)` / `X(3)`… 视为同一「知识库族」（自动改名后的旧副本）
  static bool isSameKbFamily(String existingName, String importedName) {
    if (existingName == importedName) return true;
    if (!existingName.startsWith(importedName)) return false;
    final suffix = existingName.substring(importedName.length).trim();
    return RegExp(r'^\(\d+\)$').hasMatch(suffix);
  }

  /// 导入知识库 JSON 文件：建库 → 逐文档切块落库。返回 (知识库 id, 错误)。
  /// [categoryId] 非空时直接把新库挂到该分类（分类导出包导入用）。
  ///
  /// 去重（v1.41.2 起按 uid / 内容签名，v1.41.4 起内容签名忽略库名）：
  /// 1. 文件带 `uid` 且本机已有同 uid 的知识库 → 跳过（返回 id=0 + 可读提示）；
  /// 2. 同一「知识库族」里已有**文档内容完全一致**的知识库 → 跳过；
  /// 3. 同名但内容不同 → 仍按原逻辑新建（这是两份不同资料）。
  static Future<(int, String?)> importKbFile(String filePath,
      {int? categoryId}) async {
    final (kb, docs, err) = await parseKbFile(filePath);
    if (kb == null) return (0, err);

    final uid = kb.uid?.trim();
    if (uid != null && uid.isNotEmpty) {
      final rows = await (await _db.database).query(
        'knowledge_bases',
        columns: ['id'],
        where: 'uid = ?',
        whereArgs: [uid],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return (0, '知识库「${kb.name}」已存在（uid 相同），已跳过');
      }
    }

    // 内容查重：uid 没命中也要走（可能先以老格式无 uid 导入过）
    //
    // 文档数是便宜的预筛（内容一致 ⇒ 文档数必然相同）；同族的库（`X` /
    // `X(n)`，自动编号后的副本）不看文档数，直接比内容签名，这样改名过的
    // 旧副本也不会被当成新资料。
    final sig = documentsSignature(docs);
    final db = await _db.database;
    for (final existing in await _db.getAllKnowledgeBases()) {
      final id = existing.id;
      if (id == null) continue;
      if (!isSameKbFamily(existing.name, kb.name)) {
        final rows = await db.rawQuery(
            'SELECT COUNT(*) AS c FROM kb_documents WHERE kb_id = ?', [id]);
        final count = (rows.first['c'] as int?) ?? 0;
        if (count != docs.length) continue;
      }
      final existingDocs = await _db.getKbDocuments(id);
      if (documentsSignature(existingDocs) == sig) {
        return (0, '知识库「${existing.name}」已存在（内容相同），已跳过');
      }
    }

    final target = categoryId == null ? kb : kb.copyWith(categoryId: categoryId);
    final kbId = await _db.insertKnowledgeBase(target);
    final now = DateTime.now().toIso8601String();
    for (final d in docs) {
      final docId = await _db.insertKbDocument(d.copyWith(kbId: kbId));
      final chunks = KbChunker.splitText(d.content)
          .asMap()
          .entries
          .map((e) => KbChunk(
                docId: docId,
                kbId: kbId,
                position: e.key,
                text: e.value,
                createdAt: now,
              ))
          .toList();
      await _db.insertKbChunks(chunks);
    }
    return (kbId, null);
  }

  /// 导出知识库为 JSON 文件。返回文件路径；失败返回 null。
  static Future<String?> exportKnowledgeBase(int kbId, String destPath) async {
    final kb = await _getKb(kbId);
    if (kb == null) return null;
    final docs = await _db.getKbDocuments(kbId);
    if (docs.isEmpty) return null;
    final json = const JsonEncoder.withIndent('  ').convert({
      'format': formatMarker,
      'name': kb.name,
      'description': kb.description,
      // v1.41.2：导出 uid —— 同一份知识库再次导入时按 uid 跳过
      if (kb.uid != null && kb.uid!.isNotEmpty) 'uid': kb.uid,
      // 静默写入专属 creator 标识（数据格式的专属烙印）
      'creator': NatsumePersonality.creatorMark,
      'documents': [
        for (final d in docs)
          {
            'name': d.name,
            'source': d.source,
            'file_ext': d.fileExt,
            'content': d.content,
          },
      ],
    });
    final file = File(destPath);
    await file.writeAsString(json);
    return file.path;
  }

  // ======================== 多知识库包（v1.41.4） ========================
  //
  // 以前「批量导出」要么一个库一个 JSON，要么只能按分类整包走世界包
  // （`.natsume-world`），用户没法像导出题库那样自由勾选。这里给知识库一个
  // 自己的分享包：`.natsume-kb`，本质是 zip，里面是 `kb.json` 清单 +
  // `kb/<id>.json`（每个成员都是标准 [formatMarker] 文件），所以
  // 「导入知识库」既能吃单文件，也能吃整包。

  /// 这个路径是不是一个知识库包（zip / `.natsume-kb`）。
  ///
  /// 判定「先看扩展名、再看 zip 魔数」：用户从聊天软件里收到的包可能没有
  /// 扩展名（`xxx (1)`），但有 `PK` 头就说明是 zip。
  static Future<bool> isBundleFile(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith(bundleExtension) || lower.endsWith('.zip')) return true;
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      final raf = await file.open();
      try {
        final head = await raf.read(2);
        return head.length == 2 && head[0] == 0x50 && head[1] == 0x4B;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 把多个知识库打成一个 `.natsume-kb` 包。
  ///
  /// 「没有文档」的知识库会被跳过（导出空库没有意义），跳过数由
  /// [KbBundleExportResult.skippedCount] 回报；一个都导不出时 `path = null`。
  static Future<KbBundleExportResult> exportBundle({
    required List<int> kbIds,
    required String destPath,
  }) async {
    final tmp = Directory.systemTemp.createTempSync('natsume_kb_bundle_');
    try {
      Directory('${tmp.path}/kb').createSync(recursive: true);
      final entries = <Map<String, dynamic>>[];
      var skipped = 0;
      for (final kbId in kbIds) {
        final kb = await _getKb(kbId);
        if (kb == null) {
          skipped++;
          continue;
        }
        final rel = 'kb/$kbId.json';
        final written = await exportKnowledgeBase(kbId, '${tmp.path}/$rel');
        if (written == null) {
          skipped++; // 没有文档的库跳过
          continue;
        }
        entries.add({
          'name': kb.name,
          'file': rel,
          if (kb.uid != null && kb.uid!.isNotEmpty) 'uid': kb.uid,
          if (kb.description != null && kb.description!.isNotEmpty)
            'description': kb.description,
        });
      }
      if (entries.isEmpty) {
        return KbBundleExportResult(skippedCount: skipped);
      }
      final manifest = {
        'format': bundleFormatMarker,
        'version': '1',
        'creator': NatsumePersonality.creatorMark,
        'count': entries.length,
        'knowledge_bases': entries,
      };
      File('${tmp.path}/$bundleManifestName').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(manifest));

      final archive = Archive();
      await for (final e in tmp.list(recursive: true)) {
        if (e is! File) continue;
        // Windows 路径分隔符归一为 '/'，保证 zip 条目名跨平台一致
        final rel = e.path
            .substring(tmp.path.length)
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        archive.addFile(ArchiveFile(rel, e.lengthSync(), e.readAsBytesSync()));
      }
      final out = File(destPath);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(ZipEncoder().encode(archive)!);
      return KbBundleExportResult(
        path: out.path,
        kbCount: entries.length,
        skippedCount: skipped,
      );
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 导入 `.natsume-kb` 包（一次性还原多个知识库）。
  ///
  /// 每个成员都走 [importKbFile]，因此 uid / 内容去重与单文件导入完全一致：
  /// 同一个包重复导入不会把知识库翻倍。`categoryId` 非空时整包挂到该分类。
  static Future<KbBundleImportResult> importBundle(String path,
      {int? categoryId}) async {
    final file = File(path);
    if (!await file.exists()) {
      return const KbBundleImportResult(error: '文件不存在');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    } catch (e) {
      return KbBundleImportResult(error: '不是有效的知识库包：$e');
    }

    final tmp = Directory.systemTemp.createTempSync('natsume_kb_bundle_in_');
    try {
      for (final f in archive) {
        if (!f.isFile) continue;
        // 防路径穿越：拒绝含 .. 或绝对路径的条目
        if (f.name.contains('..') || f.name.startsWith('/')) continue;
        final dest = File('${tmp.path}/${f.name}');
        dest.parent.createSync(recursive: true);
        dest.writeAsBytesSync(f.content as List<int>);
      }
      final manifestFile = File('${tmp.path}/$bundleManifestName');
      if (!manifestFile.existsSync()) {
        return const KbBundleImportResult(error: '知识库包缺少 kb.json 清单');
      }
      final dynamic manifest;
      try {
        manifest = jsonDecode(manifestFile.readAsStringSync());
      } catch (e) {
        return KbBundleImportResult(error: '知识库包清单不是合法 JSON：$e');
      }
      if (manifest is! Map || manifest['format'] != bundleFormatMarker) {
        return const KbBundleImportResult(
            error: '不是NatsumeQuizMaster知识库包（缺少 format 标记）');
      }
      final entries = manifest['knowledge_bases'];
      if (entries is! List || entries.isEmpty) {
        return const KbBundleImportResult(error: '知识库包里没有知识库');
      }

      var created = 0;
      var skipped = 0;
      String? firstSkippedReason;
      for (final raw in entries) {
        if (raw is! Map) continue;
        final rel = (raw['file'] ?? '').toString();
        if (rel.isEmpty || rel.contains('..') || rel.startsWith('/')) continue;
        final member = File('${tmp.path}/$rel');
        if (!await member.exists()) continue;
        final (id, err) =
            await importKbFile(member.path, categoryId: categoryId);
        if (id > 0) {
          created++;
        } else {
          skipped++;
          firstSkippedReason ??= err;
        }
      }
      return KbBundleImportResult(
        kbCount: created,
        skippedCount: skipped,
        // 全部被跳过不算失败：包里的东西本机都有了，调用方按「已跳过」提示
        error: created == 0 && skipped == 0
            ? (firstSkippedReason ?? '知识库包里没有可导入的内容')
            : null,
      );
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
