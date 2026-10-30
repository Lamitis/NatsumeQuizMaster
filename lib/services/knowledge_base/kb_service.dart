import 'dart:io';

import '../../models/kb_chunk.dart';
import '../../models/kb_document.dart';
import '../../models/knowledge_base.dart';
import '../database_service.dart';
import '../doc_parser_service.dart';
import '../mineru_service.dart';
import '../pdf_import_service.dart';
import 'kb_chunker.dart';
import 'kb_retriever.dart';

/// 知识库服务（v13 · 本地 RAG）。
///
/// 职责：知识库/文档/文本块的增删改查 + 文档导入（解析→切块→落库）+
/// 检索（BM25）。文档解析复用既有 `DocParserService`（docx）与
/// `PdfImportService`（pdf，本地抽字），txt/md 直接读文本。
class KbService {
  KbService._();
  static final KbService instance = KbService._();

  static final DatabaseService _db = DatabaseService.instance;

  // 检索器缓存（按 kbId），知识库变更时失效，避免每次检索都重建 BM25 索引
  final Map<int, KbRetriever> _retrievers = {};

  // ======================== 知识库 CRUD ========================

  Future<int> createKnowledgeBase(String name, {String? description}) {
    return _db.insertKnowledgeBase(KnowledgeBase(
      name: name,
      description: description,
      createdAt: DateTime.now().toIso8601String(),
    ));
  }

  Future<List<KnowledgeBase>> listKnowledgeBases() =>
      _db.getAllKnowledgeBases();

  Future<void> renameKnowledgeBase(int kbId, String name, String? description) {
    return _db.updateKnowledgeBase(KnowledgeBase(
      id: kbId,
      name: name,
      description: description,
      createdAt: DateTime.now().toIso8601String(),
    ));
  }

  Future<void> deleteKnowledgeBase(int kbId) async {
    _retrievers.remove(kbId);
    await _db.deleteKnowledgeBase(kbId);
  }

  // ======================== 文档导入 ========================

  Future<List<KbDocument>> listDocuments(int kbId) =>
      _db.getKbDocuments(kbId);

  /// 导入一个文档：解析 → 切块 → 落库。返回文档 id。
  /// [name] 为空时取文件名。
  Future<int> importDocument(int kbId, String filePath, {String? name}) async {
    final file = File(filePath);
    final ext = _extOf(filePath);
    final text = await _extractText(filePath, ext);
    if (text.trim().isEmpty) {
      throw Exception('无法从该文件解析出文本内容');
    }

    final now = DateTime.now().toIso8601String();
    final docId = await _db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: name ?? file.uri.pathSegments.last,
      source: ext,
      fileExt: ext,
      content: text,
      createdAt: now,
    ));

    final chunks = KbChunker.splitText(text)
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
    _retrievers.remove(kbId);
    return docId;
  }

  Future<void> deleteDocument(int docId) async {
    await _db.deleteKbDocument(docId);
    _retrievers.clear(); // 文档级删除难以定位 kbId，简单清空缓存
  }

  /// 重命名文档（v1.30.2）。
  ///
  /// 导入后文档名默认取文件名，`IMG_20250912_扫描件.pdf` 这类名字在检索引用
  /// 里完全是噪音——导入之后也该能改。
  Future<void> renameDocument(int docId, String name) async {
    final db = await _db.database;
    await db.update('kb_documents', {'name': name},
        where: 'id = ?', whereArgs: [docId]);
  }

  /// 把文档移动到另一个知识库（v1.30.2）：文档与它的文本块一起改归属，
  /// 两个库的检索缓存都失效（否则旧库还能检索到已搬走的切片）。
  Future<void> moveDocument(int docId, int fromKbId, int toKbId) async {
    if (fromKbId == toKbId) return;
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.update('kb_documents', {'kb_id': toKbId},
          where: 'id = ?', whereArgs: [docId]);
      await txn.update('kb_chunks', {'kb_id': toKbId},
          where: 'doc_id = ?', whereArgs: [docId]);
    });
    _retrievers.remove(fromKbId);
    _retrievers.remove(toKbId);
  }

  /// 编辑文档全文（重新切块）。供「导入后可更改调整」需求使用。
  Future<void> updateDocumentContent(int kbId, int docId, String content) async {
    final now = DateTime.now().toIso8601String();
    final chunks = KbChunker.splitText(content)
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
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.update('kb_documents', {'content': content},
          where: 'id = ?', whereArgs: [docId]);
      await txn.delete('kb_chunks', where: 'doc_id = ?', whereArgs: [docId]);
      final batch = txn.batch();
      for (final c in chunks) {
        batch.insert('kb_chunks', c.toMap());
      }
      await batch.commit(noResult: true);
    });
    _retrievers.remove(kbId);
  }

  // ======================== 检索 ========================

  Future<List<KbHit>> search(int kbId, String query, {int topK = 5}) async {
    final retriever = _retrievers[kbId] ?? await _buildRetriever(kbId);
    return retriever.search(query, topK: topK);
  }

  Future<KbRetriever> _buildRetriever(int kbId) async {
    final chunks = await _db.getKbChunks(kbId);
    final retriever = KbRetriever()..index(chunks);
    _retrievers[kbId] = retriever;
    return retriever;
  }

  void invalidate(int kbId) => _retrievers.remove(kbId);

  // ======================== 解析 ========================

  static String _extOf(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static Future<String> _extractText(String filePath, String ext) async {
    switch (ext) {
      case 'docx':
        return await DocParserService.extractRawText(filePath);
      case 'pdf':
        // v1.30.2：文字层太薄/抽不出字的 PDF（扫描件）交给 MinerU 做版面
        // 识别——知识库导入同样受「导入后不能动」之苦，能读进来才有后续。
        // MinerU 未开启或失败时，行为与从前完全一致。
        try {
          final result = await PdfImportService.extract(filePath);
          if (result.rawText.trim().length >= 200) return result.rawText;
          final mineru = await MineruService.instance.parseFile(filePath);
          return mineru?.markdown ?? result.rawText;
        } on PdfExtractException catch (e) {
          if (!e.scanned) rethrow;
          final mineru = await MineruService.instance.parseFile(filePath);
          if (mineru != null && mineru.markdown.trim().isNotEmpty) {
            return mineru.markdown;
          }
          rethrow;
        }
      case 'txt':
      case 'md':
      case 'markdown':
      default:
        return await File(filePath).readAsString();
    }
  }
}
