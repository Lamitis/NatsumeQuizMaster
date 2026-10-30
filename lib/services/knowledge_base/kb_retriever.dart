import 'dart:math';

import '../../models/kb_chunk.dart';

/// 一条检索命中：块 + BM25 分数。
class KbHit {
  final KbChunk chunk;
  final double score;

  const KbHit(this.chunk, this.score);
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
  double _avgDocLen = 0;

  static const double k1 = 1.5;
  static const double b = 0.75;

  bool get isEmpty => _chunks.isEmpty;

  void index(List<KbChunk> chunks) {
    _chunks.clear();
    _termFreqs.clear();
    _docFreq.clear();
    var totalLen = 0;
    for (var i = 0; i < chunks.length; i++) {
      _chunks.add(chunks[i]);
      final tokens = tokenize(chunks[i].text);
      totalLen += tokens.length;
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

  List<KbHit> search(String query, {int topK = 5}) {
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
        final docLen = _chunks[i].text.length;
        final norm = 1 - b + b * (docLen / (_avgDocLen == 0 ? 1 : _avgDocLen));
        final score = idf * (tf * (k1 + 1)) / (tf + k1 * norm);
        scores[i] = (scores[i] ?? 0) + score;
      }
    }

    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked
        .take(topK)
        .map((e) => KbHit(_chunks[e.key], e.value))
        .toList();
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
