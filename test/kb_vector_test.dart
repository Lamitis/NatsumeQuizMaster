import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_embedding.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_retriever.dart';

/// v1.43 向量检索的纯算法契约：
/// Float32/base64 往返、余弦相似度、TopK 排序、坏数据跳过。
void main() {
  KbChunk chunk(int id, String text, {int pos = 0}) => KbChunk(
        id: id,
        docId: 1,
        kbId: 1,
        position: pos,
        text: text,
        createdAt: '2026-11-17T00:00:00.000',
      );

  test('Float32 → base64 → Float32 往返保持数值（小端）', () {
    final vector = <double>[0.1, -0.25, 1.5, 3.0, 0.0, -2.75];
    final encoded = KbEmbedding.encodeVector(vector);
    expect(encoded, isNotEmpty);
    final decoded = KbEmbedding.decodeVector(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.length, vector.length);
    for (var i = 0; i < vector.length; i++) {
      expect(decoded[i], closeTo(vector[i], 1e-5));
    }
  });

  test('坏向量一律返回 null（不抛异常）', () {
    expect(KbEmbedding.decodeVector(null), isNull);
    expect(KbEmbedding.decodeVector(''), isNull);
    expect(KbEmbedding.decodeVector('not-base64!!'), isNull);
    // 字节数不是 4 的倍数（不是合法 Float32 序列）
    expect(KbEmbedding.decodeVector(base64Encode(const [1, 2, 3])), isNull);
  });

  test('余弦相似度：同向=1、正交=0、零向量/维度不符=null', () {
    expect(KbVectorIndex.cosineSimilarity(<double>[1, 0], <double>[1, 0]),
        closeTo(1.0, 1e-9));
    expect(KbVectorIndex.cosineSimilarity(<double>[1, 0], <double>[0, 1]),
        closeTo(0.0, 1e-9));
    expect(KbVectorIndex.cosineSimilarity(<double>[1, 2, 3], <double>[2, 4, 6]),
        closeTo(1.0, 1e-9));
    expect(
        KbVectorIndex.cosineSimilarity(<double>[0, 0], <double>[1, 0]), isNull);
    expect(KbVectorIndex.cosineSimilarity(<double>[1], <double>[1, 2]), isNull);
  });

  test('向量检索按相似度排序，取 TopK', () {
    final index = KbVectorIndex(
      chunks: [chunk(1, 'A'), chunk(2, 'B'), chunk(3, 'C')],
      vectors: <List<double>>[
        [1, 0],
        [0.9, 0.1],
        [0, 1],
      ],
    );
    final hits = index.search(<double>[1, 0], topK: 2);
    expect(hits.map((h) => h.chunk.id), [1, 2]);
    expect(hits.first.score, closeTo(1.0, 1e-9));
    expect(hits[1].score, closeTo(0.9938, 1e-3));
  });

  test('维度不一致 / 负相关被跳过，不会把无关块喂给模型', () {
    final index = KbVectorIndex(
      chunks: [chunk(1, 'A'), chunk(2, 'B'), chunk(3, 'C')],
      vectors: <List<double>>[
        [1, 0],
        [1, 0, 0], // 维度不符
        [-1, 0], // 完全负相关（minScore=0 时过滤）
      ],
    );
    final hits = index.search(<double>[1, 0], topK: 5);
    expect(hits.map((h) => h.chunk.id), [1]);
  });

  test('空索引 / 空查询返回空列表', () {
    const index = KbVectorIndex(chunks: [], vectors: []);
    expect(index.search(<double>[1, 0]), isEmpty);
    final filled = KbVectorIndex(
      chunks: [chunk(1, 'A')],
      vectors: <List<double>>[
        [1, 0]
      ],
    );
    expect(filled.search(const <double>[]), isEmpty);
  });
}
