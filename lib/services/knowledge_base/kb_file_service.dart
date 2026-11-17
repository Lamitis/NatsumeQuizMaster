import 'dart:async';
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
import 'kb_service.dart';

/// 知识库包导出结果（`.zip`：一个 zip 里装多个知识库）。
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

  /// 知识库包清单的格式标记（v1.43）。
  ///
  /// v1.43 起包后缀统一为 `.zip`（系统文件管理器 / 微信 / QQ 才认得出是文件），
  /// 因此不能再靠后缀区分「知识库包 / 世界包」——改成读包内清单的 `format`：
  /// `natsume-kb` = 知识库包，`natsume-world` = 世界 / 分类包。
  static const String bundleFormatMarker = 'natsume-kb';

  /// v1.42 及更早的知识库包标记（旧包仍可导入）
  static const String legacyBundleFormatMarker = 'natsume-kb-bundle';

  /// 多知识库包的后缀：本质是 zip，强制 `.zip` 以便分享 / 系统识别。
  static const String bundleExtension = '.zip';

  /// 旧版知识库包后缀（仍接受导入）
  static const String legacyBundleExtension = '.natsume-kb';

  /// 包内清单文件名
  static const String bundleManifestName = 'kb.json';

  /// 单文件导出的强制后缀（v1.42）。
  ///
  /// Windows / Android 都靠后缀决定「双击用什么打开」，文件选择器也靠它
  /// 把导出文件列进「知识库 JSON」筛选项。
  static const String singleFileExtension = '.json';

  /// 单文件导出文件名：清掉路径分隔符等非法字符，并强制 `.json` 后缀。
  ///
  /// 以前调用方直接拿 `kb.name` 拼路径：名字里带 `/`、`:` 时写入会失败
  /// （Windows 甚至把它当成子目录），生成的文件也可能没有后缀、认不出类型。
  static String singleExportFileName(String name) {
    final safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final base = safe.isEmpty ? '知识库' : safe;
    return base.toLowerCase().endsWith(singleFileExtension)
        ? base
        : '$base$singleFileExtension';
  }

  /// 确保导出路径带 `.json`。
  ///
  /// 批量包 / 世界包成员本来就传 `kb/<id>.json`，这里原样返回；
  /// 单文件导出传什么都会补齐后缀，保证「导出 → 导入」闭环。
  static String ensureSingleFileExtension(String destPath) =>
      destPath.toLowerCase().endsWith(singleFileExtension)
          ? destPath
          : '$destPath$singleFileExtension';

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
    if (data is! Map) {
      return (null, const <KbDocument>[], '不是NatsumeQuizMaster知识库文件（根节点必须是对象）');
    }
    // v1.42：兼容「外层包装」写法——有的导出流程会把标准知识库塞进
    // `{"wrapper": ..., "knowledge_base": {...}}`；只要内层带 format 标记就能读。
    var payload = data;
    if (payload['format'] != formatMarker) {
      final nested = payload['knowledge_base'];
      if (nested is Map && nested['format'] == formatMarker) {
        payload = Map<String, dynamic>.from(nested);
      }
    }
    if (payload['format'] != formatMarker) {
      return (
        null,
        const <KbDocument>[],
        '不是NatsumeQuizMaster知识库文件（缺少 format 标记）'
      );
    }
    final docsRaw = payload['documents'];
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
    final uidRaw = payload['uid']?.toString().trim();
    return (
      KnowledgeBase(
        name: (payload['name'] ?? '导入知识库').toString(),
        description: payload['description']?.toString(),
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

    final target =
        categoryId == null ? kb : kb.copyWith(categoryId: categoryId);
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
    // v1.43：从文件导入的知识库同样异步补向量（未开启 / 不支持时返回 0）。
    // 不 await：导入结果先返回，向量化在后台跑。
    unawaited(KbService.instance.ensureEmbeddings(kbId));
    return (kbId, null);
  }

  /// 导出知识库为 JSON 文件。返回文件路径；失败返回 null。
  ///
  /// v1.42 修复：无论调用方给的目标路径带不带后缀，落盘文件一定是 `.json`；
  /// 内容里补齐 `version` / `kind` / `document_count` / `exported_at` 等识别
  /// 标记，和批量包同一口径——导入端只认 `format`，多出来的字段是给人看的。
  static Future<String?> exportKnowledgeBase(int kbId, String destPath) async {
    final kb = await _getKb(kbId);
    if (kb == null) return null;
    final docs = await _db.getKbDocuments(kbId);
    if (docs.isEmpty) return null;
    final dest = ensureSingleFileExtension(destPath);
    final json = const JsonEncoder.withIndent('  ').convert({
      'format': formatMarker,
      // v1.42：单文件也带版本 / 类型头，识别端不必靠文件名猜
      'version': '1',
      'kind': 'single',
      'name': kb.name,
      'description': kb.description,
      // v1.41.2：导出 uid —— 同一份知识库再次导入时按 uid 跳过
      if (kb.uid != null && kb.uid!.isNotEmpty) 'uid': kb.uid,
      // 静默写入专属 creator 标识（数据格式的专属烙印）
      'creator': NatsumePersonality.creatorMark,
      'document_count': docs.length,
      'exported_at': DateTime.now().toIso8601String(),
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
    final file = File(dest);
    await file.parent.create(recursive: true);
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

  /// 这个路径是不是「知识库包」：只认 zip 内部 `kb.json` 的 format 标记。
  ///
  /// v1.43：后缀统一成 `.zip` 后，同一后缀可能装知识库包 / 世界包 / 普通压缩包，
  /// 仅凭后缀会误判。这里解压读清单（包很小，代价可接受）：
  /// - `format` = `natsume-kb`（新）/ `natsume-kb-bundle`（旧）→ true；
  /// - 其他（包括 world 包）→ false。
  static Future<bool> isBundleFile(String path) async {
    final data = await _readZipJson(path, bundleManifestName);
    if (data == null) return false;
    final format = data['format'];
    return format == bundleFormatMarker || format == legacyBundleFormatMarker;
  }

  /// 这个 zip 是不是「世界 / 分类导出包」（`world.json` + format=natsume-world）。
  ///
  /// v1.42：知识库页的「导出分类」产物是 `.natsume-world.zip`，用户很自然
  /// 会拿「导入知识库」去还原它。这里先认出来，交给 `WorldService.importWorld`
  /// 处理，而不是报「缺少 kb.json 清单」。
  static Future<bool> isWorldFile(String path) async {
    final data = await _readZipJson(path, 'world.json');
    return data != null && data['format'] == 'natsume-world';
  }

  /// 仅按 zip 魔数判断「是不是压缩包」（不判断包类型）。
  static Future<bool> isZipFile(String path) async {
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

  /// 读取 zip 内某个 JSON 文件；不存在 / 不是 zip / 解析失败一律返回 null。
  static Future<Map<String, dynamic>?> _readZipJson(
      String path, String entryName) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    } catch (_) {
      return null;
    }
    for (final f in archive) {
      if (!f.isFile || f.name != entryName) continue;
      try {
        final decoded = jsonDecode(utf8.decode(f.content as List<int>));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    return null;
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
        'type': 'knowledge_bases',
        'creator': NatsumePersonality.creatorMark,
        'exported_at': DateTime.now().toIso8601String(),
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
        return const KbBundleImportResult(
            error: '知识库包缺少 kb.json 清单（若是分类 / 世界导出包，'
                '请用「导入知识库」重新选择，或到「世界」页导入）');
      }
      final dynamic manifest;
      try {
        manifest = jsonDecode(manifestFile.readAsStringSync());
      } catch (e) {
        return KbBundleImportResult(error: '知识库包清单不是合法 JSON：$e');
      }
      if (manifest is! Map ||
          (manifest['format'] != bundleFormatMarker &&
              manifest['format'] != legacyBundleFormatMarker)) {
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
