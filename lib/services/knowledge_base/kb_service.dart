import 'dart:async';
import 'dart:io';

import '../../models/kb_chunk.dart';
import '../../models/kb_document.dart';
import '../../models/kb_embedding.dart';
import '../../models/knowledge_base.dart';
import '../database_service.dart';
import '../doc_parser_service.dart';
import '../mineru_service.dart';
import '../pdf_import_service.dart';
import 'kb_chunker.dart';
import 'kb_embedding_service.dart';
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

  // 向量索引缓存（key = `kbId::model`）：换模型自然命中新的 key，旧索引不会被误用
  final Map<String, KbVectorIndex> _vectorIndexes = {};

  /// 正在后台补齐向量的知识库：防止每次检索都重复发一轮 Embedding 请求。
  final Set<int> _backfilling = {};

  /// 向量化配置（由 AppState 在设置加载 / 保存后注入）。
  KbEmbeddingConfig? _embeddingConfig;

  /// 当前是否真的走向量检索（开关 + Key + 供应商都满足）。
  bool get vectorSearchActive => _embeddingConfig?.usable ?? false;

  /// AppState 每次设置变化时调用；停用 / 换模型 / 换端点时清掉向量缓存。
  void configure(KbEmbeddingConfig? config) {
    final old = _embeddingConfig;
    _embeddingConfig = config;
    if (old?.storageKey != config?.storageKey ||
        old?.enabled != config?.enabled) {
      _vectorIndexes.clear();
    }
  }

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
    _clearVectorCache(kbId);
    await _db.deleteKnowledgeBase(kbId);
  }

  Future<void> setKnowledgeBaseCategory(int kbId, int? categoryId) =>
      _db.setKnowledgeBaseCategory(kbId, categoryId);

  /// 批量删除知识库（v1.39.3）：清掉内存检索器后一次性落库。
  Future<void> deleteKnowledgeBases(Iterable<int> kbIds) async {
    final ids = kbIds.toSet().toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      _retrievers.remove(id);
      _clearVectorCache(id);
    }
    await _db.deleteKnowledgeBases(ids);
  }

  // ======================== 文档导入 ========================

  Future<List<KbDocument>> listDocuments(int kbId) => _db.getKbDocuments(kbId);

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
    _clearVectorCache(kbId);
    // v1.43：向量化必须**异步**——导入不能被 Embedding 请求拖慢；
    // 失败（未配置 / 断网）只记日志，检索仍走 BM25。
    unawaited(indexDocumentEmbeddings(kbId, docId));
    return docId;
  }

  Future<void> deleteDocument(int docId) async {
    await _db.deleteKbDocument(docId);
    _retrievers.clear(); // 文档级删除难以定位 kbId，简单清空缓存
    _vectorIndexes.clear();
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
      await txn.update('kb_embeddings', {'kb_id': toKbId},
          where: 'chunk_id IN (SELECT id FROM kb_chunks WHERE doc_id = ?)',
          whereArgs: [docId]);
    });
    _retrievers.remove(fromKbId);
    _retrievers.remove(toKbId);
    _clearVectorCache(fromKbId);
    _clearVectorCache(toKbId);
  }

  /// 编辑文档全文（重新切块）。供「导入后可更改调整」需求使用。
  Future<void> updateDocumentContent(
      int kbId, int docId, String content) async {
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
      await txn.delete('kb_embeddings',
          where: 'chunk_id IN (SELECT id FROM kb_chunks WHERE doc_id = ?)',
          whereArgs: [docId]);
      await txn.delete('kb_chunks', where: 'doc_id = ?', whereArgs: [docId]);
      final batch = txn.batch();
      for (final c in chunks) {
        batch.insert('kb_chunks', c.toMap());
      }
      await batch.commit(noResult: true);
    });
    _retrievers.remove(kbId);
    _clearVectorCache(kbId);
    // 正文变了，旧向量作废：异步重建
    unawaited(indexDocumentEmbeddings(kbId, docId));
  }

  // ======================== 检索 ========================

  /// 检索知识库：开启向量化且已有向量时用余弦相似度，否则回退 BM25。
  ///
  /// 关键取舍：
  /// - **查询向量失败**（弱网 / Key 失效）→ 静默回退 BM25，不打断 AI 回答；
  /// - **还没有向量**（老库 / 刚打开开关）→ 本次先 BM25，同时后台补齐向量，
  ///   下一次检索自动切到语义检索；
  /// - 向量检索取 Top K 的余弦相似度结果（Top 3~5 与调用方 topK 一致）。
  Future<List<KbHit>> search(int kbId, String query, {int topK = 5}) async {
    final config = _embeddingConfig;
    if (config != null && config.usable && query.trim().isNotEmpty) {
      final index = await _vectorIndexFor(kbId, config.storageKey);
      if (index == null || index.isEmpty) {
        // 后台补齐（不 await）：这次先用 BM25，不让首问等待几十次请求
        _scheduleBackfill(kbId);
      } else {
        final queryVector =
            await KbEmbeddingService.instance.embedQuery(query, config);
        if (queryVector != null) {
          final hits = index.search(queryVector, topK: topK);
          if (hits.isNotEmpty) return hits;
        }
      }
    }
    final retriever = _retrievers[kbId] ?? await _buildRetriever(kbId);
    return retriever.search(query, topK: topK);
  }

  Future<KbRetriever> _buildRetriever(int kbId) async {
    final chunks = await _db.getKbChunks(kbId);
    final retriever = KbRetriever()..index(chunks);
    _retrievers[kbId] = retriever;
    return retriever;
  }

  /// 取（并缓存）某个知识库的向量索引；没有向量返回 null。
  Future<KbVectorIndex?> _vectorIndexFor(int kbId, String model) async {
    final key = '$kbId::$model';
    final cached = _vectorIndexes[key];
    if (cached != null) return cached;
    final embeddings = await _db.getKbEmbeddings(kbId, model: model);
    if (embeddings.isEmpty) return null;
    final chunks = await _db.getKbChunks(kbId);
    final byId = <int, KbChunk>{
      for (final c in chunks)
        if (c.id != null) c.id!: c,
    };
    final pairs = <KbChunk>[];
    final vectors = <List<double>>[];
    for (final e in embeddings) {
      final chunk = byId[e.chunkId];
      if (chunk == null) continue;
      if (e.vector.isEmpty || e.vector.length != e.dim) continue;
      pairs.add(chunk);
      vectors.add(e.vector);
    }
    if (pairs.isEmpty) return null;
    final index = KbVectorIndex(chunks: pairs, vectors: vectors);
    _vectorIndexes[key] = index;
    return index;
  }

  /// 为某个文档补齐向量（导入 / 正文编辑后调用；异步执行）。
  ///
  /// 返回成功写入的块数；未开启向量化 / 请求失败返回 0。
  Future<int> indexDocumentEmbeddings(int kbId, int docId,
      {bool force = false}) async {
    final config = _embeddingConfig;
    if (config == null || !config.usable) return 0;
    final chunks = await _db.getKbChunksByDoc(docId);
    if (chunks.isEmpty) return 0;
    final existing = force
        ? const <int>{}
        : (await _db.getKbEmbeddings(kbId, model: config.storageKey))
            .map((e) => e.chunkId)
            .toSet();
    final pending =
        chunks.where((c) => c.id != null && !existing.contains(c.id)).toList();
    return _embedChunks(kbId, pending, config);
  }

  /// 后台补齐某个库的向量；同一个库同时只跑一轮（失败也会释放标记）。
  void _scheduleBackfill(int kbId) {
    if (_backfilling.contains(kbId)) return;
    _backfilling.add(kbId);
    unawaited(() async {
      try {
        await ensureEmbeddings(kbId);
      } finally {
        _backfilling.remove(kbId);
      }
    }());
  }

  /// 为某个知识库补齐所有缺失向量（老库首次检索 / 打开开关后的回填）。
  Future<int> ensureEmbeddings(int kbId) async {
    final config = _embeddingConfig;
    if (config == null || !config.usable) return 0;
    final pending =
        await _db.getKbChunksMissingEmbedding(kbId, config.storageKey);
    return _embedChunks(kbId, pending, config);
  }

  /// 为所有知识库补齐向量（设置里打开开关时后台触发）。
  Future<int> ensureAllEmbeddings() async {
    final config = _embeddingConfig;
    if (config == null || !config.usable) return 0;
    var total = 0;
    for (final kb in await _db.getAllKnowledgeBases()) {
      final id = kb.id;
      if (id == null) continue;
      total += await ensureEmbeddings(id);
    }
    return total;
  }

  Future<int> _embedChunks(
      int kbId, List<KbChunk> chunks, KbEmbeddingConfig config) async {
    if (chunks.isEmpty) return 0;
    var written = 0;
    // 双阈值分批：条数 ≤16、总字符 ≤6000。中文 1000 字的块 16 条会超过
    // text-embedding-3-small 的 8191 token 上限，按字符数收口更稳。
    var start = 0;
    while (start < chunks.length) {
      var end = start;
      var chars = 0;
      while (end < chunks.length &&
          end - start < KbEmbeddingService.defaultBatchSize) {
        final len = chunks[end].text.length;
        if (end > start && chars + len > 6000) break;
        chars += len;
        end++;
      }
      final batch = chunks.sublist(start, end);
      start = end;
      final vectors = await KbEmbeddingService.instance
          .embedAll(batch.map((c) => c.text).toList(), config);
      if (vectors == null || vectors.length != batch.length) break;
      final now = DateTime.now().toIso8601String();
      final items = <KbEmbedding>[];
      for (var j = 0; j < batch.length; j++) {
        final id = batch[j].id;
        final vector = vectors[j];
        if (id == null || vector.isEmpty) continue;
        items.add(KbEmbedding(
          chunkId: id,
          kbId: kbId,
          model: config.storageKey,
          dim: vector.length,
          vector: vector,
          createdAt: now,
        ));
      }
      await _db.upsertKbEmbeddings(items);
      written += items.length;
    }
    if (written > 0) _clearVectorCache(kbId);
    return written;
  }

  void _clearVectorCache(int kbId) {
    _vectorIndexes.removeWhere((key, _) => key.startsWith('$kbId::'));
  }

  void invalidate(int kbId) {
    _retrievers.remove(kbId);
    _clearVectorCache(kbId);
  }

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
