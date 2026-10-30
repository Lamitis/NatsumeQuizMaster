import 'dart:convert';
import 'dart:io';

import '../../models/kb_chunk.dart';
import '../../models/kb_document.dart';
import '../../models/knowledge_base.dart';
import '../../utils/natsume_personality.dart';
import '../database_service.dart';
import 'kb_chunker.dart';

/// 知识库导出/导入（v13）。
///
/// 格式仿 `BankFileService`：单 JSON 文件，带 `format` 标记 + 知识库名 +
/// 文档列表（含解析后的全文 `content`，可被导入直接切块入库，闭环往返）。
/// 导入时按文档名去重建库（不覆盖已有知识库，重名自动编号由调用方处理）。
class KbFileService {
  KbFileService._();

  static final DatabaseService _db = DatabaseService.instance;

  static const String formatMarker = 'natsume-knowledge-base';

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
    return (
      KnowledgeBase(
        name: (data['name'] ?? '导入知识库').toString(),
        description: data['description']?.toString(),
        createdAt: now,
      ),
      docs,
      null,
    );
  }

  /// 导入知识库 JSON 文件：建库 → 逐文档切块落库。返回 (知识库 id, 错误)。
  static Future<(int, String?)> importKbFile(String filePath) async {
    final (kb, docs, err) = await parseKbFile(filePath);
    if (kb == null) return (0, err);
    final kbId = await _db.insertKnowledgeBase(kb);
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
}
