/// 知识库文本切块（v13）。
///
/// 移植自 NoteLLM（MIT，Copyright (c) 2025 勒亦昂）的 `app/utils/chunking.py`：
/// 该实现用 LangChain `RecursiveCharacterTextSplitter`，分隔符依次为
/// `["\n\n", "\n", ".", " ", ""]`、`chunk_size=1000`、`chunk_overlap=200`。
///
/// 这里用纯 Dart 复刻「递归分隔符切分」的语义：优先在段落/换行/句号/空格
/// 边界切开，切不动再退回按字符硬切，保证每块语义尽量完整、块长 ≤ chunkSize。
/// 与 NoteLLM 的一个有意差异：**不做 overlap**——约束检索会把这些块原文注入
/// 提示词，overlap 会造成相邻块内容重复、检索结果冗余，故省略并在此说明。
class KbChunker {
  const KbChunker._();

  /// 默认分隔符顺序（与 NoteLLM 对齐；中文句号 `。` 补在原 `.` 之后）
  static const List<String> defaultSeparators = ['\n\n', '\n', '。', '.', ' ', ''];

  static const int defaultChunkSize = 1000;

  static List<String> splitText(String text,
      {int chunkSize = defaultChunkSize}) {
    return _recursive(text, defaultSeparators, 0, chunkSize);
  }

  static List<String> _recursive(
      String text, List<String> seps, int startIdx, int chunkSize) {
    if (text.length <= chunkSize) {
      final t = text.trim();
      return t.isEmpty ? const [] : [t];
    }

    // 找当前文本中出现的第一个分隔符
    String? sep;
    var nextIdx = startIdx;
    for (var i = startIdx; i < seps.length; i++) {
      if (seps[i].isEmpty || text.contains(seps[i])) {
        sep = seps[i];
        nextIdx = i;
        break;
      }
    }

    // 无可用的语义分隔符 → 退回按字符硬切
    if (sep == null || sep.isEmpty) {
      return _hardSplit(text, chunkSize);
    }

    final pieces = text.split(sep);
    final chunks = <String>[];
    final buf = StringBuffer();
    for (final p in pieces) {
      if (p.length > chunkSize) {
        // 单段仍超长：先落当前缓冲，再降级到下一级分隔符递归
        if (buf.isNotEmpty) {
          chunks.add(buf.toString().trim());
          buf.clear();
        }
        final deeperStart = nextIdx + 1 >= seps.length ? nextIdx : nextIdx + 1;
        chunks.addAll(_recursive(p, seps, deeperStart, chunkSize));
      } else {
        final candidate = buf.isEmpty ? p : '$buf$sep$p';
        if (candidate.length <= chunkSize) {
          if (buf.isNotEmpty) buf.write(sep);
          buf.write(p);
        } else {
          chunks.add(buf.toString().trim());
          buf.clear();
          buf.write(p);
        }
      }
    }
    if (buf.isNotEmpty) {
      final tail = buf.toString().trim();
      if (tail.isNotEmpty) chunks.add(tail);
    }
    return chunks;
  }

  /// 无分隔符时的退路：按 chunkSize 硬切成定长块（尽量落在字符边界）。
  static List<String> _hardSplit(String text, int chunkSize) {
    final out = <String>[];
    for (var i = 0; i < text.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, text.length);
      out.add(text.substring(i, end).trim());
    }
    return out.where((s) => s.isNotEmpty).toList();
  }
}
