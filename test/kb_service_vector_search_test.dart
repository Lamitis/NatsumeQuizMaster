import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/models/kb_embedding.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_embedding_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';

/// v1.43 向量检索接线：向量命中优先、未启用/无向量回退 BM25、
/// 向量写入/读取/删除随文档与知识库级联。
void main() {
  late Directory tmp;

  const config = KbEmbeddingConfig(
    enabled: true,
    apiKey: 'k',
    apiEndpoint: 'https://api.example.com/v1',
    model: 'test-embed',
    providerKind: AiProviderKind.openaiCompat,
  );

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_kb_vector_');
    DatabaseService.overrideDbPath = '${tmp.path}/t.db';
    KbEmbeddingService.resetUnsupportedForTest();
    KbService.instance.configure(null);
  });

  tearDown(() async {
    KbEmbeddingService.embedOverrideForTest = null;
    KbService.instance.configure(null);
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 两个块：
  /// - A（语义近）：文本里**没有**「休克」二字，但向量 [1,0] 与查询一致；
  /// - B（关键词近）：文本含「休克」，向量 [0,1] 与查询正交。
  /// 用它区分「向量检索」和 BM25，而不是两个都会命中。
  Future<({int kbId, int docId, List<KbChunk> chunks})> seed() async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance.createKnowledgeBase('向量测试库');
    final docId = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: 'doc.md',
      content: '循环血量不足会引起组织灌注下降。休克的典型表现是血压下降。',
      createdAt: '2026-11-17T00:00:00.000',
    ));
    await db.insertKbChunks([
      KbChunk(
        docId: docId,
        kbId: kbId,
        position: 0,
        text: '循环血量不足会引起组织灌注下降。',
        createdAt: '2026-11-17T00:00:00.000',
      ),
      KbChunk(
        docId: docId,
        kbId: kbId,
        position: 1,
        text: '休克的典型表现是血压下降。',
        createdAt: '2026-11-17T00:00:00.000',
      ),
    ]);
    final chunks = await db.getKbChunksByDoc(docId);
    await db.upsertKbEmbeddings([
      KbEmbedding(
        chunkId: chunks[0].id!,
        kbId: kbId,
        model: config.model,
        dim: 2,
        vector: const [1, 0],
        createdAt: '2026-11-17T00:00:00.000',
      ),
      KbEmbedding(
        chunkId: chunks[1].id!,
        kbId: kbId,
        model: config.model,
        dim: 2,
        vector: const [0, 1],
        createdAt: '2026-11-17T00:00:00.000',
      ),
    ]);
    return (kbId: kbId, docId: docId, chunks: chunks);
  }

  test('开启向量：按余弦取 TopK，优先语义块而不是关键词块', () async {
    final s = await seed();
    KbService.instance.configure(config);
    // 查询向量与 A 同向
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async => [
          for (final _ in texts) <double>[1, 0]
        ];

    final hits = await KbService.instance.search(s.kbId, '休克', topK: 3);
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.text, contains('循环血量不足'));
    expect(hits.first.score, closeTo(1.0, 1e-6));
  });

  test('关闭向量：回退 BM25，关键词块命中', () async {
    final s = await seed();
    KbService.instance.configure(null);
    KbService.instance.invalidate(s.kbId);

    final hits = await KbService.instance.search(s.kbId, '休克', topK: 3);
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.text, contains('休克的典型表现'));
  });

  test('查询向量失败（断网/Key 失效）：静默回退 BM25', () async {
    final s = await seed();
    KbService.instance.configure(config);
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async => null;

    final hits = await KbService.instance.search(s.kbId, '休克', topK: 3);
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.text, contains('休克的典型表现'));
  });

  test('ensureEmbeddings：只补缺失向量，返回写入块数', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    // 清空后用注入的向量重建
    await (await db.database).delete('kb_embeddings');
    KbService.instance.configure(config);
    var calls = 0;
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async {
      calls++;
      return [
        for (final _ in texts) <double>[0.5, 0.5]
      ];
    };

    final written = await KbService.instance.ensureEmbeddings(s.kbId);
    expect(written, 2);
    expect(calls, 1);
    final stored = await db.getKbEmbeddings(s.kbId, model: config.model);
    expect(stored, hasLength(2));
    expect(stored.every((e) => e.dim == 2), isTrue);
    // 再跑一次：没有缺失，不再请求
    calls = 0;
    expect(await KbService.instance.ensureEmbeddings(s.kbId), 0);
    expect(calls, 0);
  });

  test('换模型后旧向量视为缺失，按新模型重建', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    final missing =
        await db.getKbChunksMissingEmbedding(s.kbId, 'another-model');
    expect(missing, hasLength(2));
    final sameModel =
        await db.getKbChunksMissingEmbedding(s.kbId, config.model);
    expect(sameModel, isEmpty);
  });

  test('删除文档 / 知识库：向量级联清理', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    await db.deleteKbDocument(s.docId);
    expect(await db.getKbEmbeddings(s.kbId), isEmpty);

    // 再建一份并删除整个知识库
    final s2 = await seed();
    expect(await db.getKbEmbeddings(s2.kbId), hasLength(2));
    await KbService.instance.deleteKnowledgeBase(s2.kbId);
    expect(await db.getKbEmbeddings(s2.kbId), isEmpty);
  });
}
