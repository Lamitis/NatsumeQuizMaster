import 'dart:convert';
import 'dart:typed_data';

/// 知识库文本块的向量（v1.43）。
///
/// 存储取舍：一条 embedding 与 `kb_chunks` 一对一，单独建表而不是给
/// `kb_chunks` 加列——BM25 检索不需要读向量，分开存可以避免每次全量
/// 加载文本块时把几 MB 的向量一起读出来。
///
/// 向量用 `Float32List` + base64 存 TEXT：
/// - 1536 维 ≈ 6 KB 二进制 → 8 KB base64，比 JSON 数组（约 20 KB）省一半；
/// - 不引入原生扩展（sqflite 无法加载 sqlite-vss），余弦相似度在 Dart 侧算。
class KbEmbedding {
  final int chunkId;
  final int kbId;

  /// 生成向量时使用的模型名（换模型后旧向量视为缺失，需要重建）。
  final String model;
  final int dim;
  final List<double> vector;
  final String createdAt;

  const KbEmbedding({
    required this.chunkId,
    required this.kbId,
    required this.model,
    required this.dim,
    required this.vector,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'chunk_id': chunkId,
        'kb_id': kbId,
        'model': model,
        'dim': dim,
        'vector': encodeVector(vector),
        'created_at': createdAt,
      };

  factory KbEmbedding.fromMap(Map<String, dynamic> map) {
    final vector = decodeVector(map['vector']?.toString());
    return KbEmbedding(
      chunkId: map['chunk_id'] as int,
      kbId: map['kb_id'] as int,
      model: map['model']?.toString() ?? '',
      dim: map['dim'] as int? ?? (vector?.length ?? 0),
      vector: vector ?? const [],
      createdAt: map['created_at']?.toString() ?? '',
    );
  }

  /// Float32（小端）→ base64。
  static String encodeVector(List<double> vector) {
    final data = ByteData(vector.length * 4);
    for (var i = 0; i < vector.length; i++) {
      data.setFloat32(i * 4, vector[i], Endian.little);
    }
    return base64Encode(data.buffer.asUint8List());
  }

  /// base64 → Float32（小端）；坏数据返回 null（旧库 / 手改过的值）。
  static List<double>? decodeVector(String? encoded) {
    if (encoded == null || encoded.trim().isEmpty) return null;
    try {
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty || bytes.length % 4 != 0) return null;
      final data = ByteData.sublistView(bytes);
      final out = List<double>.filled(bytes.length ~/ 4, 0);
      for (var i = 0; i < out.length; i++) {
        out[i] = data.getFloat32(i * 4, Endian.little);
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}
