/// 小鲸助教回复的文本清洗（v1.43）。
///
/// 模型经常把整段回答包在 ```` ```markdown ```` 里，或者只写开头围栏。
/// 聊天气泡用 Markdown 渲染器展示时，外层围栏会变成一整块代码区域，看起来
/// 像「源码泄漏」。这里只剥掉**最外层**围栏，正文里真正的代码块原样保留。
String cleanCompanionMarkdown(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.isEmpty) return text;
  final lines = text.split('\n');

  bool isFence(String line) => RegExp(r'^```[ \t]*$').hasMatch(line.trim());
  bool isMarkdownFence(String line) => RegExp(
        r'^```[ \t]*(?:markdown|md)[ \t]*$',
        caseSensitive: false,
      ).hasMatch(line.trim());

  final fenceIndexes = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].trim().startsWith('```')) i,
  ];
  final firstIsFence = fenceIndexes.isNotEmpty && fenceIndexes.first == 0;
  final lastIsFence =
      fenceIndexes.isNotEmpty && fenceIndexes.last == lines.length - 1;
  final firstIsMarkdownFence = firstIsFence && isMarkdownFence(lines.first);

  if (firstIsMarkdownFence) {
    // 开头明确写了 ```markdown：后面的收尾围栏一起剥掉
    lines.removeAt(0);
    if (lines.isNotEmpty && isFence(lines.last)) lines.removeLast();
  } else if (firstIsFence && lastIsFence && fenceIndexes.length == 2) {
    // 整段只有一个无名围栏：``` ... ``` → 去掉首尾
    lines.removeLast();
    lines.removeAt(0);
  } else if (fenceIndexes.length.isOdd && lastIsFence) {
    // 只有结尾围栏（模型漏了开头）：去掉，避免把后面的正文当代码块
    lines.removeLast();
  }

  return lines
      .join('\n')
      .replaceAll('\u200B', '')
      .replaceAll('\u200C', '')
      .replaceAll('\u200D', '')
      .trim();
}

/// 打字机阶段的纯文本预览：先不渲染 Markdown，但把常见标记符号去掉，
/// 避免用户在中途看到 `**` / `###` 这类源码（最终全文仍用富文本渲染）。
String companionTypingPreview(String raw) {
  var text = cleanCompanionMarkdown(raw);
  if (text.isEmpty) return text;
  text = text.replaceAllMapped(
      RegExp(r'^#{1,6}[ \t]+', multiLine: true), (_) => '');
  text = text.replaceAll('**', '').replaceAll('__', '');
  // 行内代码 `x` → x；表格分隔行 |---| 保留会显脏，直接压成空格
  text = text.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m.group(1) ?? '');
  text = text.replaceAll(
      RegExp(r'^[ \t]*\|?[\s:|-]+\|?[ \t]*$', multiLine: true), '');
  return text.trim();
}
