import 'dart:math';
import 'dart:typed_data';

import '../../models/kb_chunk.dart';

/// 一条检索命中：块 + 相关性分数（[VectorScore]/[KeywordScore] 是分路明细）。
///
/// v1.44 起多带了两条明细分数（都允许为 null，表示这条路径没给出分数）：
/// 界面/诊断页要能回答「这条资料是靠关键词命中的，还是靠语义命中的」——
/// 纯向量检索会漏掉「术语/数字/公式」这类必须逐字匹配的内容，只有两条都
/// 摆出来才判得清检索到底可不可靠。
class KbHit {
  final KbChunk chunk;

  /// 融合后的相关性分（0~1 量级）。非混合检索时就是该路原始分。
  final double score;

  /// 向量检索原始余弦相似度（-1~1；没走向量时为 null）
  final double? vectorScore;

  /// BM25 原始分（没走关键词时为 null）
  final double? keywordScore;

  const KbHit(
    this.chunk,
    this.score, {
    this.vectorScore,
    this.keywordScore,
  });

  /// 是否由关键词（逐字匹配）路径命中——诊断用。
  bool get matchedByKeyword => keywordScore != null && keywordScore! > 0;

  /// 是否由语义路径命中——诊断用。
  bool get matchedByVector => vectorScore != null && vectorScore! > 0;

  /// 复制并替换分数（混合检索融合用）。
  KbHit withScore(double fused, {double? vector, double? keyword}) => KbHit(
        chunk,
        fused,
        vectorScore: vector ?? vectorScore,
        keywordScore: keyword ?? keywordScore,
      );

  @override
  String toString() => 'KbHit(${chunk.position}, score=${score.toStringAsFixed(3)},'
      ' v=${vectorScore?.toStringAsFixed(3)}, k=${keywordScore?.toStringAsFixed(3)})';
}

/// 向量索引（内存里的一份快照 + 暴力余弦）。
///
/// 内存取舍（v1.44，手机端优化）：向量用 `Float32List` 存而不是
/// `List<double>`——1536 维的块在 Dart 里是 8 字节/维，Float32 只要 4 字节，
/// 一个三千块的知识库能省下约 18 MB 堆内存，而余弦相似度对 float32 精度
/// 完全不敏感。构造参数仍接受 `List<double>`，调用方不必关心存储细节。
class KbVectorIndex {
  final List<KbChunk> chunks;

  /// 与 [chunks] 一一对应的向量（float32）；维度不一致的条目在检索时跳过。
  final List<Float32List> vectors;

  /// 用普通 double 列表构造：内部统一转成 float32。
  factory KbVectorIndex({
    required List<KbChunk> chunks,
    required List<List<double>> vectors,
  }) =>
      KbVectorIndex._(
        chunks,
        [
          for (final v in vectors)
            v is Float32List ? v : Float32List.fromList(v),
        ],
      );

  const KbVectorIndex._(this.chunks, this.vectors);

  /// 空索引（供调用方判空用，避免每次新建一个空对象）
  static const KbVectorIndex empty =
      KbVectorIndex._(<KbChunk>[], <Float32List>[]);

  bool get isEmpty => chunks.isEmpty || vectors.isEmpty;

  int get length => chunks.length;

  /// 余弦相似度；零向量 / 维度不一致返回 null（调用方跳过该块）。
  static double? cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return null;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na <= 0 || nb <= 0) return null;
    return dot / (sqrt(na) * sqrt(nb));
  }

  /// 向量检索：按余弦相似度取 Top K。
  ///
  /// [minScore] 默认 0：只过滤掉负相关（完全不相关）的块；embedding 的
  /// 相似度通常是 0.6~0.9，不能像 BM25 那样要求正分才有意义。
  /// [docIds] 非空时只在这些文档的块里检索（「按文件出题」用）。
  List<KbHit> search(
    List<double> query, {
    int topK = 5,
    double minScore = 0,
    Set<int>? docIds,
  }) {
    if (isEmpty || query.isEmpty) return const [];
    final scored = <KbHit>[];
    for (var i = 0; i < chunks.length && i < vectors.length; i++) {
      final chunk = chunks[i];
      if (docIds != null && docIds.isNotEmpty && !docIds.contains(chunk.docId)) {
        continue;
      }
      final score = cosineSimilarity(query, vectors[i]);
      if (score == null || score < minScore) continue;
      scored.add(KbHit(chunk, score, vectorScore: score));
    }
    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      // 分数并列时按块 id / 位置稳定排序，结果可复现
      final ai = a.chunk.id ?? a.chunk.position;
      final bi = b.chunk.id ?? b.chunk.position;
      return ai.compareTo(bi);
    });
    return scored.take(topK).toList();
  }
}

/// 知识库检索器（v13 · 全本地、零二进制依赖）。
///
/// 默认用 **BM25**（关键词稀疏检索）：纯 Dart 实现，离线可用，不需要本地
/// embedding 模型运行时。为中文做了 CJK 二元组（bigram）分词——中文没有空格，
/// 逐字或按整句都不理想，相邻两字成词最稳。
///
/// 接口上预留了未来接本地语义 embedding 的位置：`search` 只依赖已 `index`
/// 的块与查询文本，可替换为向量检索而不改调用方。
class KbRetriever {
  final List<KbChunk> _chunks = [];
  final Map<int, Map<String, int>> _termFreqs = {}; // chunk 下标 → 词频
  final Map<String, int> _docFreq = {}; // 词 → 出现该词的块数
  final List<int> _chunkTokenLens = []; // 每块 token 数（BM25 长度归一用）
  double _avgDocLen = 0;

  static const double k1 = 1.5;
  static const double b = 0.75;

  bool get isEmpty => _chunks.isEmpty;

  int get length => _chunks.length;

  /// 已索引块的平均 token 长度（诊断页展示用）。
  double get averageDocLength => _avgDocLen;

  void index(List<KbChunk> chunks) {
    _chunks.clear();
    _termFreqs.clear();
    _docFreq.clear();
    _chunkTokenLens.clear();
    var totalLen = 0;
    for (var i = 0; i < chunks.length; i++) {
      _chunks.add(chunks[i]);
      final tokens = tokenize(chunks[i].text);
      totalLen += tokens.length;
      _chunkTokenLens.add(tokens.length);
      final tf = <String, int>{};
      for (final t in tokens) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      _termFreqs[i] = tf;
      for (final t in tf.keys) {
        _docFreq[t] = (_docFreq[t] ?? 0) + 1;
      }
    }
    _avgDocLen = chunks.isEmpty ? 0 : totalLen / chunks.length;
  }

  /// BM25 检索。
  ///
  /// v1.44 两处修正：
  /// - 长度归一改用 **token 数**（以前用 `text.length` 字符数，与词频口径
  ///   不一致，中文块会被系统性地过度惩罚）；
  /// - 支持 [docIds] 限定检索范围（「只对某几个文件出题」）。
  List<KbHit> search(
    String query, {
    int topK = 5,
    Set<int>? docIds,
    double minScore = 0,
  }) {
    if (_chunks.isEmpty || query.trim().isEmpty) return const [];
    final qTokens = tokenize(query);
    final n = _chunks.length;

    final scores = <int, double>{};
    for (final t in qTokens.toSet()) {
      final df = _docFreq[t] ?? 0;
      if (df == 0) continue;
      // IDF：ln(1 + (N - df + 0.5) / (df + 0.5))
      final idf = log(1 + (n - df + 0.5) / (df + 0.5));
      for (var i = 0; i < n; i++) {
        final tf = _termFreqs[i]?[t] ?? 0;
        if (tf == 0) continue;
        final docLen = _chunkTokenLens[i];
        final norm = 1 - b + b * (docLen / (_avgDocLen == 0 ? 1 : _avgDocLen));
        final score = idf * (tf * (k1 + 1)) / (tf + k1 * norm);
        scores[i] = (scores[i] ?? 0) + score;
      }
    }

    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <KbHit>[];
    for (final e in ranked) {
      final chunk = _chunks[e.key];
      if (docIds != null &&
          docIds.isNotEmpty &&
          !docIds.contains(chunk.docId)) {
        continue;
      }
      if (e.value < minScore) continue;
      out.add(KbHit(chunk, e.value, keywordScore: e.value));
      if (out.length >= topK) break;
    }
    return out;
  }

  /// 分词：ASCII 字母/数字按词切，连续 CJK 字按二元组切。
  static List<String> tokenize(String s) {
    final tokens = <String>[];
    final ascii = StringBuffer();
    final cjk = StringBuffer();

    void flushAscii() {
      if (ascii.isNotEmpty) {
        tokens.add(ascii.toString().toLowerCase());
        ascii.clear();
      }
    }

    void flushCjk() {
      final t = cjk.toString();
      cjk.clear();
      if (t.isEmpty) return;
      if (t.length == 1) {
        tokens.add(t);
        return;
      }
      for (var i = 0; i + 1 < t.length; i++) {
        tokens.add(t.substring(i, i + 2));
      }
    }

    for (final r in s.runes) {
      if (_isCjk(r)) {
        flushAscii();
        cjk.writeCharCode(r);
      } else if (_isAsciiAlnum(r)) {
        flushCjk();
        ascii.writeCharCode(r);
      } else {
        flushAscii();
        flushCjk();
      }
    }
    flushAscii();
    flushCjk();
    return tokens;
  }

  static bool _isCjk(int codePoint) =>
      (codePoint >= 0x3400 && codePoint <= 0x4DBF) ||
      (codePoint >= 0x4E00 && codePoint <= 0x9FFF) ||
      (codePoint >= 0xF900 && codePoint <= 0xFAFF);

  static bool _isAsciiAlnum(int codePoint) =>
      (codePoint >= 0x30 && codePoint <= 0x39) || // 0-9
      (codePoint >= 0x41 && codePoint <= 0x5A) || // A-Z
      (codePoint >= 0x61 && codePoint <= 0x7A); // a-z
}
