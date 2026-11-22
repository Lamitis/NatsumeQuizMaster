import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/models/kb_embedding.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_embedding_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';

/// v1.44 混合检索（向量 + BM25）契约。
///
/// 为什么不再「有向量就只用向量」：纯向量对**必须逐字命中**的内容是弱项
/// （医学名词、缩写、公式、数字），实测会把含数值的那一段挤出 TopK，解析于是
/// 引用了错资料；反过来纯 BM25 又漏同义改写。混合检索要求两路都算，并按名次
/// 加权融合，同时保留「按文档限定范围」的能力（出题范围用）。
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
    tmp = Directory.systemTemp.createTempSync('natsume_kb_hybrid_');
    DatabaseService.overrideDbPath = '${tmp.path}/t.db';
    KbEmbeddingService.resetUnsupportedForTest();
    KbEmbeddingService.embedOverrideForTest = null;
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

  /// 两个文档各一个块：
  /// - A（语义近 / 无关键词）：文本里**没有**「休克」，向量与查询同向；
  /// - B（关键词近 / 语义远）：文本含「休克」，向量与查询正交。
  Future<({int kbId, int docA, int docB, List<KbChunk> chunks})> seed() async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance.createKnowledgeBase('混合检索库');
    final docA = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: 'a-循环生理.md',
      content: '循环血量不足会引起组织灌注下降。',
      createdAt: '2026-11-20T00:00:00.000',
    ));
    final docB = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: 'b-休克.md',
      content: '休克的典型表现是血压下降。',
      createdAt: '2026-11-20T00:00:00.000',
    ));
    await db.insertKbChunks([
      KbChunk(
        docId: docA,
        kbId: kbId,
        position: 0,
        text: '循环血量不足会引起组织灌注下降。',
        createdAt: '2026-11-20T00:00:00.000',
      ),
      KbChunk(
        docId: docB,
        kbId: kbId,
        position: 0,
        text: '休克的典型表现是血压下降。',
        createdAt: '2026-11-20T00:00:00.000',
      ),
    ]);
    final chunks = await db.getKbChunks(kbId);
    await db.upsertKbEmbeddings([
      KbEmbedding(
        chunkId: chunks.firstWhere((c) => c.docId == docA).id!,
        kbId: kbId,
        model: config.storageKey,
        dim: 2,
        vector: const [1, 0],
        createdAt: '2026-11-20T00:00:00.000',
      ),
      KbEmbedding(
        chunkId: chunks.firstWhere((c) => c.docId == docB).id!,
        kbId: kbId,
        model: config.storageKey,
        dim: 2,
        vector: const [0, 1],
        createdAt: '2026-11-20T00:00:00.000',
      ),
    ]);
    return (kbId: kbId, docA: docA, docB: docB, chunks: chunks);
  }

  test('混合检索：语义块与关键词块都进结果，且标出各自命中来源', () async {
    final s = await seed();
    KbService.instance.configure(config);
    // 查询向量与 A 同向（B 正交）
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async => [
          for (final _ in texts) <double>[1, 0]
        ];

    final hits = await KbService.instance.searchHybrid(s.kbId, '休克', topK: 5);
    expect(hits, hasLength(2), reason: '两路命中合起来应是两个块，且不重复计名次');

    final fromA = hits.firstWhere((h) => h.chunk.text.contains('循环血量不足'));
    final fromB = hits.firstWhere((h) => h.chunk.text.contains('休克的典型表现'));

    expect(fromA.matchedByVector, isTrue, reason: 'A 靠语义命中');
    expect(fromB.matchedByKeyword, isTrue, reason: 'B 靠关键词命中（纯向量会漏掉它）');
  });

  test('docIds 限定：只在选定的文档里检索（按文件出题）', () async {
    final s = await seed();
    KbService.instance.configure(config);
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async => [
          for (final _ in texts) <double>[1, 0]
        ];

    final onlyB = await KbService.instance
        .searchHybrid(s.kbId, '休克', topK: 5, docIds: {s.docB});
    expect(onlyB, hasLength(1));
    expect(onlyB.single.chunk.docId, s.docB);
    expect(onlyB.single.chunk.text, contains('休克'));

    final onlyA = await KbService.instance
        .searchHybrid(s.kbId, '休克', topK: 5, docIds: {s.docA});
    expect(onlyA.single.chunk.docId, s.docA);
  });

  test('未启用向量：混合检索退化为纯关键词，结果仍可用', () async {
    final s = await seed();
    KbService.instance.configure(null);
    KbService.instance.invalidate(s.kbId);

    final hits = await KbService.instance.searchHybrid(s.kbId, '休克', topK: 5);
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.text, contains('休克'));
    expect(hits.every((h) => !h.matchedByVector), isTrue);
  });

  test('跨库检索只发一次查询向量，多库结果合并排序', () async {
    final s = await seed();
    final kb2 = await KbService.instance.createKnowledgeBase('第二库');
    final db = DatabaseService.instance;
    final docC = await db.insertKbDocument(KbDocument(
      kbId: kb2,
      name: 'c-电解质.md',
      content: '低钾血症会导致心肌兴奋性改变。',
      createdAt: '2026-11-20T00:00:00.000',
    ));
    await db.insertKbChunks([
      KbChunk(
        docId: docC,
        kbId: kb2,
        position: 0,
        text: '低钾血症会导致心肌兴奋性改变。',
        createdAt: '2026-11-20T00:00:00.000',
      ),
    ]);
    KbService.instance.configure(config);
    var embeddingCalls = 0;
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async {
      embeddingCalls++;
      return [
        for (final _ in texts) <double>[1, 0]
      ];
    };

    final hits = await KbService.instance
        .searchAcrossKnowledgeBases([s.kbId, kb2], '休克', topKPerKb: 3);
    expect(hits, isNotEmpty);
    expect(embeddingCalls, 1,
        reason: '多个知识库共用一次查询向量：手机端不能每个库发一次请求');
    // 合并后按分数降序
    for (var i = 1; i < hits.length; i++) {
      expect(hits[i - 1].score, greaterThanOrEqualTo(hits[i].score));
    }
  });

  test('诊断报告：给出覆盖率、平均块长与可执行建议', () async {
    final s = await seed();
    KbService.instance.configure(config);
    KbEmbeddingService.embedOverrideForTest = (texts, cfg) async => [
          for (final _ in texts) <double>[1, 0]
        ];

    final report =
        await KbService.instance.diagnose(s.kbId, sampleQuery: '休克');
    expect(report.documentCount, 2);
    expect(report.chunkCount, 2);
    expect(report.embeddedChunkCount, 2);
    expect(report.embeddingCoverage, closeTo(1.0, 1e-9));
    expect(report.vectorEnabled, isTrue);
    expect(report.probeQuery, '休克');
    expect(report.hybridHits, isNotEmpty);
    expect(report.advice, isNotEmpty);
  });
}
