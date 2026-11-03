import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../services/theme_service.dart';
import '../../utils/design_tokens.dart';

/// 统一的富文本 / Markdown 渲染引擎（v1.40）。
///
/// **为什么还是自研分块**：v1.0.2 起 AI 回复就走自研 span 渲染器——
/// `flutter_markdown` 对「中文全角标点紧跟闭合星号」（`**定性/计算**：`）
/// 会原样吐出源码，项目里也因此积累了一批以「不残留 `**` / `|` / `##`」
/// 为契约的测试。v1.40 只补上工科题真正缺的四块能力，不推倒重来：
///
/// 1. **LaTeX**：`$...$` 行内、`$$...$$` 块级，交给 `flutter_math_fork`
///    排版（纯 Dart，带 KaTeX 字体资产，桌面/安卓一致）；
/// 2. **表格**：GFM 表格 → 有边框的 [Table]，外面套横向滚动
///    （`TableSyntax` 的等价能力，窄屏不溢出）；
/// 3. **代码高亮**：```lang 围栏代码块 → `flutter_highlight`（highlight.js
///    语法），未知语言自动回落纯文本；
/// 4. **基础 HTML**：`<mark>` 高亮、`<span style="color: #HEX">` 彩色文本
///    （笔记工具栏写的就是这两种标签）。
///
/// 行内标记与结构色（答案/题眼/避坑指南…）沿用旧渲染器的口径，
/// 所以 `AiResponseWidget` 的行为保持兼容，只是多了上面四件事。
class NatsumeMarkdown extends StatelessWidget {
  const NatsumeMarkdown({
    super.key,
    required this.text,
    this.style,
    this.fontSize,
    this.color,
    this.aiSections = false,
    this.onWikiLink,
    this.selectable = false,
  });

  /// Markdown / LaTeX / 基础 HTML 混排正文
  final String text;

  /// 基准样式（缺省 [NatsumeType.bodyStyle]）
  final TextStyle? style;

  /// 覆盖基准字号（AI 解析卡会按场景传 13/14）
  final double? fontSize;

  /// 覆盖正文颜色
  final Color? color;

  /// 是否套用 AI 解析的结构色（答案=绿 / 题眼=蓝 / 避坑指南=红底…）。
  /// 笔记预览传 false：笔记的结构标签应由用户自己写，不该被系统染色。
  final bool aiSections;

  /// `[[双链]]` 点击回调（双链笔记用；不传则只显示文字）
  final void Function(String target)? onWikiLink;

  /// 是否包一层 [SelectionArea]（笔记预览需要能复制）
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final base = (style ?? NatsumeType.bodyStyle).copyWith(
      fontSize: fontSize ?? style?.fontSize,
      color: color ?? style?.color ?? ac.textPrimary,
      height: style?.height ?? 1.65,
    );
    // 纯文本快路径（v1.40）：题干/选项绝大多数是纯文字，没有标记时直接
    // 交给 [Text] —— 省一次分块解析，也让 `find.text('题干')`、读屏软件与
    // 旧的无障碍标签保持原样（走 Text.rich 会因块内换行多出 `\n`）。
    if (!aiSections && !hasNatsumeMarkdown(text)) {
      final plain = Text(text, style: base);
      return selectable ? SelectionArea(child: plain) : plain;
    }
    final blocks = parseNatsumeBlocks(text);
    final children = <Widget>[];
    for (final block in blocks) {
      children.add(_buildBlock(context, block, base, ac));
    }
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    return selectable ? SelectionArea(child: column) : column;
  }

  Widget _buildBlock(
    BuildContext context,
    NatsumeMdBlock block,
    TextStyle base,
    AppThemeColors ac,
  ) {
    switch (block.kind) {
      case NatsumeMdBlockKind.table:
        return _buildTable(block, base, ac);
      case NatsumeMdBlockKind.code:
        return _buildCode(context, block, base, ac);
      case NatsumeMdBlockKind.math:
        return _buildMathBlock(block.tex, base, ac);
      case NatsumeMdBlockKind.text:
        return _buildTextBlock(block, base, ac);
    }
  }

  // ======================== 文本块（单 RichText） ========================

  Widget _buildTextBlock(
      NatsumeMdBlock block, TextStyle base, AppThemeColors ac) {
    final baseSize = base.fontSize ?? NatsumeType.body;
    final spans = <InlineSpan>[];
    for (final line in block.lines) {
      final sz = switch (line.headingLevel) {
        1 => baseSize + 6,
        2 => baseSize + 4,
        3 => baseSize + 2,
        _ => baseSize,
      };
      final sec = aiSections ? _sectionStyle(line.section, ac) : const _Sec();
      final lineStyle = base.copyWith(
        fontSize: sz,
        fontWeight:
            line.headingLevel > 0 || sec.bold ? FontWeight.bold : null,
        color: sec.color ?? base.color,
        backgroundColor: sec.background,
      );
      spans.add(TextSpan(style: lineStyle, children: [
        if (line.leading.isNotEmpty) TextSpan(text: line.leading),
        ...buildNatsumeInlineSpans(
          line.content,
          base: lineStyle,
          ac: ac,
          onWikiLink: onWikiLink,
        ),
      ]));
      // 单块内换行仍由一个 RichText 承担：旧渲染器的结构色测试
      // （test/ai_chat_test.dart）就是按「首个 RichText 里能看到三种颜色」
      // 写的，拆成每行一个 Text 会让它变脆。
      spans.add(const TextSpan(text: '\n'));
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }

  // ======================== 表格（边框 + 横向滚动） ========================

  Widget _buildTable(NatsumeMdBlock block, TextStyle base, AppThemeColors ac) {
    final baseSize = base.fontSize ?? NatsumeType.body;
    final columns =
        block.rows.map((r) => r.length).fold<int>(0, (m, n) => n > m ? n : m);
    if (columns == 0) return const SizedBox.shrink();

    final table = Table(
      border: TableBorder.all(color: ac.border, width: NatsumeLine.width),
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: block.rows.take(40).toList().asMap().entries.map((entry) {
        final isHead = entry.key == 0;
        return TableRow(
          decoration: isHead ? BoxDecoration(color: ac.surfaceAlt) : null,
          children: List.generate(columns, (c) {
            final cell = c < entry.value.length ? entry.value[c] : '';
            final cellBase = base.copyWith(
              fontSize: baseSize - 1,
              height: 1.4,
              fontWeight: isHead ? FontWeight.bold : FontWeight.normal,
            );
            return Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: NatsumeSpace.xs + 2, vertical: 4),
              child: Text.rich(TextSpan(
                style: cellBase,
                children: buildNatsumeInlineSpans(
                  cell,
                  base: cellBase,
                  ac: ac,
                  onWikiLink: onWikiLink,
                ),
              )),
            );
          }),
        );
      }).toList(),
    );

    // 窄屏不溢出：表格按内容取宽，外层吃横向滚动
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NatsumeSpace.xxs),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth:
                  constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
            ),
            child: table,
          ),
        ),
      ),
    );
  }

  // ======================== 代码块（语法高亮） ========================

  Widget _buildCode(
    BuildContext context,
    NatsumeMdBlock block,
    TextStyle base,
    AppThemeColors ac,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final baseSize = base.fontSize ?? NatsumeType.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NatsumeSpace.xxs),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1E2227) : ac.surfaceAlt,
          borderRadius: NatsumeRadius.cardBorder,
          border: Border.all(color: ac.border, width: NatsumeLine.width),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(NatsumeSpace.sm),
          child: HighlightView(
            block.code,
            // HighlightView 的 language 传 null 会抛 ArgumentError（highlight
            // 包的 parse 要求显式语言，自动识别要另开 autoDetection），
            // 所以未知语言一律交给 plaintext：宁可不上色，也不要炸掉整页。
            language: normalizeHighlightLanguage(block.language),
            theme: dark ? atomOneDarkTheme : githubTheme,
            padding: EdgeInsets.zero,
            textStyle: TextStyle(
              fontFamily: 'monospace',
              fontSize: baseSize - 1,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  // ======================== 块级公式 ========================

  Widget _buildMathBlock(String tex, TextStyle base, AppThemeColors ac) {
    final baseSize = base.fontSize ?? NatsumeType.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NatsumeSpace.xxs),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
        decoration: BoxDecoration(
          color: ac.surfaceAlt,
          borderRadius: NatsumeRadius.cardBorder,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Math.tex(
            tex,
            mathStyle: MathStyle.display,
            textStyle: base.copyWith(
              fontSize: baseSize + 2,
              color: base.color ?? ac.textPrimary,
            ),
            // 公式写错（AI 偶发）时把源码原样给用户，不要抛一屏红色异常
            onErrorFallback: (_) => Text(
              tex,
              style: base.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
      ),
    );
  }

  /// 结构标签 → 颜色/字重/底色（沿用 v1.28 口径）
  _Sec _sectionStyle(String? section, AppThemeColors ac) {
    switch (section) {
      case '答案':
        return _Sec(color: ac.success, bold: true);
      case '题眼':
        return _Sec(color: ac.accent, bold: true);
      case '解析':
        return const _Sec(bold: true);
      case '避坑指南':
        return _Sec(color: ac.danger, bold: true, background: ac.dangerSoft);
      case '一句话记忆':
        return _Sec(color: ac.accent, bold: true, background: ac.accentSoft);
      default:
        return const _Sec();
    }
  }
}

// ======================== 块级解析（纯函数，便于单测） ========================

enum NatsumeMdBlockKind { text, table, code, math }

/// 一个块：文本块带行、表格带行列表、代码带语言、公式带 TeX 源
class NatsumeMdBlock {
  NatsumeMdBlock.text(this.lines)
      : kind = NatsumeMdBlockKind.text,
        rows = const [],
        code = '',
        language = '',
        tex = '';
  NatsumeMdBlock.table(this.rows)
      : kind = NatsumeMdBlockKind.table,
        lines = const [],
        code = '',
        language = '',
        tex = '';
  NatsumeMdBlock.code(this.code, this.language)
      : kind = NatsumeMdBlockKind.code,
        lines = const [],
        rows = const [],
        tex = '';
  NatsumeMdBlock.math(this.tex)
      : kind = NatsumeMdBlockKind.math,
        lines = const [],
        rows = const [],
        code = '',
        language = '';

  final NatsumeMdBlockKind kind;
  final List<NatsumeMdLine> lines;
  final List<List<String>> rows;
  final String code;
  final String language;
  final String tex;
}

/// 文本块里的一行：前导符号（`•` / `1.`）+ 标题级别 + 结构标签 + 正文
class NatsumeMdLine {
  const NatsumeMdLine({
    this.leading = '',
    this.headingLevel = 0,
    this.section,
    required this.content,
  });

  final String leading;
  final int headingLevel;
  final String? section;
  final String content;
}

class _Sec {
  const _Sec({this.color, this.background, this.bold = false});
  final Color? color;
  final Color? background;
  final bool bold;
}

/// 判断一段文字是否含需要解析的标记（纯文本快路径的判据）。
///
/// 只做「有没有」的正则探测，不追求精确：宁可多走一遍解析，也不要漏掉
/// 公式/表格/代码这类真正需要渲染的内容。
@visibleForTesting
bool hasNatsumeMarkdown(String text) {
  if (text.contains(RegExp(r'[*_`$<>\[\]|]'))) return true;
  return RegExp(r'(^|\n)\s*(?:#{1,6}\s|[-+]\s|\d+\.\s|>\s)').hasMatch(text);
}

/// 结构标签行：`**答案：** B` / `答案：B` / `### 解析：…` 都认
final RegExp _sectionLine = RegExp(
    r'^\*{0,2}(答案|题眼|解析|避坑指南|一句话记忆)[：:]\*{0,2}\s*');

/// 块级切分：空行分段，围栏代码 / 块级公式 / GFM 表格各自成块。
///
/// 与旧渲染器的差别只有「多了代码块与块级公式两条分支」，
/// 其余（标题、列表、结构标签、表格分隔行的判定）保持同一口径。
@visibleForTesting
List<NatsumeMdBlock> parseNatsumeBlocks(String raw) {
  final blocks = <NatsumeMdBlock>[];
  final lines = raw.split('\n');
  var i = 0;

  String trimLeft(String s) => s.replaceFirst(RegExp(r'^\s+'), '');

  while (i < lines.length) {
    final line = trimLeft(lines[i]);
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // ```lang 围栏代码块（未闭合也照常渲染，避免整段被吞掉）
    if (line.startsWith('```')) {
      final lang = line.substring(3).trim();
      final code = <String>[];
      i++;
      while (i < lines.length && !trimLeft(lines[i]).startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 吃掉闭合围栏
      blocks.add(NatsumeMdBlock.code(code.join('\n'), lang));
      continue;
    }

    // $$ 块级公式（$$ 单独一行时向下找到闭合行）
    if (line.startsWith(r'$$')) {
      final rest = line.substring(2);
      if (rest.trim().endsWith(r'$$') && rest.trim().length >= 2) {
        blocks.add(NatsumeMdBlock.math(
            rest.trim().substring(0, rest.trim().length - 2).trim()));
        i++;
        continue;
      }
      final tex = StringBuffer(rest);
      i++;
      var closed = false;
      while (i < lines.length) {
        final l = lines[i];
        final end = l.indexOf(r'$$');
        if (end >= 0) {
          tex
            ..write('\n')
            ..write(l.substring(0, end));
          i++;
          closed = true;
          break;
        }
        tex
          ..write('\n')
          ..write(l);
        i++;
      }
      blocks.add(NatsumeMdBlock.math(tex.toString().trim()));
      if (!closed) continue;
      continue;
    }

    // GFM 表格：| a | b | + |---|---|
    if (line.startsWith('|') &&
        i + 1 < lines.length &&
        _isTableDivider(trimLeft(lines[i + 1]))) {
      final rows = <List<String>>[_splitTableRow(line)];
      i += 2;
      while (i < lines.length) {
        final l = trimLeft(lines[i]);
        if (!l.startsWith('|')) break;
        rows.add(_splitTableRow(l));
        i++;
      }
      blocks.add(NatsumeMdBlock.table(rows));
      continue;
    }

    // 文本块：连续非空、非表格、非围栏/公式的行聚合
    final textLines = <NatsumeMdLine>[];
    while (i < lines.length) {
      final l = trimLeft(lines[i]);
      if (l.isEmpty) break;
      if (l.startsWith('```') || l.startsWith(r'$$')) break;
      if (l.startsWith('|') &&
          i + 1 < lines.length &&
          _isTableDivider(trimLeft(lines[i + 1]))) {
        break;
      }
      textLines.add(_parseTextLine(l));
      i++;
    }
    if (textLines.isNotEmpty) blocks.add(NatsumeMdBlock.text(textLines));
  }
  return blocks;
}

bool _isTableDivider(String line) {
  if (!line.startsWith('|') || line.length < 4) return false;
  final rest = line
      .replaceAll('|', '')
      .replaceAll('-', '')
      .replaceAll(':', '')
      .trim();
  return rest.isEmpty;
}

List<String> _splitTableRow(String line) => line
    .trim()
    .replaceAll(RegExp(r'^\|'), '')
    .replaceAll(RegExp(r'\|$'), '')
    .split('|')
    .map((c) => c.trim())
    .toList();

/// 单行 → 结构标签 / 标题级别 / 列表前导符 + 正文
NatsumeMdLine _parseTextLine(String input) {
  var line = input;
  // 结构标签优先：`**答案：**` 与 `答案：` 都要能认出来
  final sec = _sectionLine.firstMatch(line);
  if (sec != null) {
    final name = sec.group(1)!;
    final rest = line.substring(sec.end).replaceAll('**', '');
    return NatsumeMdLine(leading: '$name：', section: name, content: rest.trimRight());
  }

  var headingLevel = 0;
  final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
  if (heading != null) {
    headingLevel = heading.group(1)!.length;
    line = heading.group(2)!;
  } else if (line.startsWith('> ')) {
    line = line.substring(2);
  }

  var leading = '';
  if (RegExp(r'^\s*[-*+]\s+').hasMatch(line)) {
    leading = '•  ';
    line = line.replaceFirst(RegExp(r'^\s*[-*+]\s+'), '');
  } else {
    final ol = RegExp(r'^\s*(\d+)\.\s+').firstMatch(line);
    if (ol != null) {
      leading = '${ol.group(1)}. ';
      line = line.substring(ol.end);
    }
  }
  return NatsumeMdLine(
      leading: leading, headingLevel: headingLevel, content: line.trimRight());
}

// ======================== 行内解析（Markdown + HTML + LaTeX） ========================

/// `<span style="color: xxx">` 的开标签（单/双引号都认）
final RegExp _colorSpanOpen = RegExp(
    r'<span\s+style\s*=\s*["\u0027]\s*color\s*:\s*([^;"\u0027]+)\s*;?\s*["\u0027]\s*>');

const Map<String, Color> _namedColors = {
  'red': Color(0xFFE5484D),
  'blue': Color(0xFF2F6FEB),
  'green': Color(0xFF2E9E5B),
  'orange': Color(0xFFF0821E),
  'purple': Color(0xFF8E4EC6),
  'pink': Color(0xFFE93D82),
  'yellow': Color(0xFFD6A400),
  'gray': Color(0xFF6B7280),
  'grey': Color(0xFF6B7280),
  'black': Color(0xFF111111),
  'white': Color(0xFFFFFFFF),
};

/// 解析 HTML 里的颜色值：`#RGB` / `#RRGGBB` / `#AARRGGBB` / 常用英文色名。
///
/// 认不出来就返回 null——调用方按「不是颜色标签」原样显示，
/// 而不是画一段透明文字让用户以为内容丢了。
@visibleForTesting
Color? parseMarkdownColor(String raw) {
  final v = raw.trim().replaceAll(';', '').trim().toLowerCase();
  if (v.isEmpty) return null;
  final named = _namedColors[v];
  if (named != null) return named;
  if (!v.startsWith('#')) return null;
  var hex = v.substring(1);
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length == 6) hex = 'ff$hex';
  if (hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  return value == null ? null : Color(value);
}

/// 代码围栏语言 → highlight.js 语言名（别名归一；未知回落 plaintext）
@visibleForTesting
String normalizeHighlightLanguage(String lang) {
  final v = lang.trim().toLowerCase();
  if (v.isEmpty) return 'plaintext';
  const alias = {
    'js': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'py': 'python',
    'sh': 'bash',
    'shell': 'bash',
    'zsh': 'bash',
    'yml': 'yaml',
    'c++': 'cpp',
    'cc': 'cpp',
    'h': 'cpp',
    'cs': 'csharp',
    'c#': 'csharp',
    'kt': 'kotlin',
    'rb': 'ruby',
    'rs': 'rust',
    'md': 'markdown',
    'tex': 'latex',
    'html': 'xml',
  };
  return alias[v] ?? v;
}

/// 从 [from] 起找行内公式的收尾 `$`（[display] 为 true 时找 `$$`）。
///
/// 三条启发式专治「$ 也被当钱花」的日常文本：
/// 1. 不跨行；2. 内容不能为空；3. 内容首尾不能是空格。
/// 匹配不到就返回 null，交给调用方按普通文本输出。
int? _findClosingMath(String s, int from, {required bool display}) {
  final marker = display ? r'$$' : r'$';
  var j = from;
  while (j < s.length) {
    if (s[j] == '\n') return null;
    if (s.startsWith(marker, j) && (j == 0 || s[j - 1] != r'\')) {
      final content = s.substring(from, j);
      if (content.trim().isEmpty) return null;
      if (content.length > 300) return null;
      if (content.startsWith(' ') || content.endsWith(' ')) return null;
      return j;
    }
    j++;
  }
  return null;
}

/// 行内标记 → [InlineSpan] 列表。
///
/// 支持：`**粗体**`、`*斜体*`、`` `行内代码` ``、`==蓝关键词==`、
/// `!!红关键词!!`、`<mark>高亮</mark>`、`<span style="color:#HEX">彩色</span>`、
/// `$行内公式$`、`$$行内展示公式$$`、`[[双链]]`。
///
/// 任何标记未闭合都按普通文本原样输出（容错口径与 v1.0.2 一致）：
/// 宁可让用户看到源码，也不吞掉后面的正文。
List<InlineSpan> buildNatsumeInlineSpans(
  String source, {
  required TextStyle base,
  required AppThemeColors ac,
  void Function(String target)? onWikiLink,
  int depth = 0,
}) {
  final spans = <InlineSpan>[];
  if (source.isEmpty) return spans;
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    spans.add(TextSpan(text: buf.toString(), style: base));
    buf.clear();
  }

  final baseSize = base.fontSize ?? NatsumeType.body;
  var i = 0;
  while (i < source.length) {
    final ch = source[i];

    // 反斜杠转义：\$ 星号等按原字符输出（LaTeX 命令在 $...$ 内部不受影响）
    if (ch == r'\' && i + 1 < source.length) {
      final next = source[i + 1];
      if (r'\$*_`[]<>'.contains(next)) {
        buf.write(next);
        i += 2;
        continue;
      }
    }

    // <mark>高亮</mark>
    if (source.startsWith('<mark>', i)) {
      final end = source.indexOf('</mark>', i + 6);
      if (end != -1) {
        flush();
        spans.addAll(buildNatsumeInlineSpans(
          source.substring(i + 6, end),
          base: base.copyWith(
            backgroundColor: ac.warningSoft,
            color: base.color ?? ac.textPrimary,
            fontWeight: FontWeight.w600,
          ),
          ac: ac,
          onWikiLink: onWikiLink,
          depth: depth + 1,
        ));
        i = end + 7;
        continue;
      }
    }

    // <span style="color: xxx">彩色</span>
    if (source.startsWith('<span', i)) {
      final open = _colorSpanOpen.matchAsPrefix(source, i);
      if (open != null) {
        final end = source.indexOf('</span>', open.end);
        final color = parseMarkdownColor(open.group(1) ?? '');
        if (end != -1 && color != null) {
          flush();
          spans.addAll(buildNatsumeInlineSpans(
            source.substring(open.end, end),
            base: base.copyWith(color: color),
            ac: ac,
            onWikiLink: onWikiLink,
            depth: depth + 1,
          ));
          i = end + 7;
          continue;
        }
      }
    }

    // $$...$$（行内展示公式）与 $...$（行内公式）
    if (ch == r'$') {
      final isDisplay = source.startsWith(r'$$', i);
      final openLen = isDisplay ? 2 : 1;
      final close = _findClosingMath(source, i + openLen, display: isDisplay);
      if (close != null) {
        final tex = source.substring(i + openLen, close);
        flush();
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(
            tex,
            mathStyle: isDisplay ? MathStyle.display : MathStyle.text,
            textStyle: base.copyWith(
              fontSize: baseSize,
              color: base.color ?? ac.textPrimary,
            ),
            onErrorFallback: (_) => Text(
              isDisplay ? '\$\$$tex\$\$' : '\$$tex\$',
              style: base.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ));
        i = close + openLen;
        continue;
      }
    }

    // **粗体**
    if (source.startsWith('**', i)) {
      final end = source.indexOf('**', i + 2);
      if (end > i + 2) {
        flush();
        spans.addAll(buildNatsumeInlineSpans(
          source.substring(i + 2, end),
          base: base.copyWith(fontWeight: FontWeight.bold),
          ac: ac,
          onWikiLink: onWikiLink,
          depth: depth + 1,
        ));
        i = end + 2;
        continue;
      }
    }

    // `行内代码`
    if (ch == '`' && !source.startsWith('```', i)) {
      final end = source.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        spans.add(TextSpan(
          text: source.substring(i + 1, end),
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: baseSize - 1,
            backgroundColor: ac.surfaceAlt,
          ),
        ));
        i = end + 1;
        continue;
      }
    }

    // ==蓝关键词== / !!红关键词!!
    if (source.startsWith('==', i) || source.startsWith('!!', i)) {
      final marker = source.substring(i, i + 2);
      final end = source.indexOf(marker, i + 2);
      if (end > i + 2) {
        flush();
        spans.add(TextSpan(
          text: source.substring(i + 2, end),
          style: base.copyWith(
            color: marker == '==' ? ac.accent : ac.danger,
            fontWeight: FontWeight.bold,
          ),
        ));
        i = end + 2;
        continue;
      }
    }

    // [[双链]] / [[目标|别名]]
    if (source.startsWith('[[', i)) {
      final end = source.indexOf(']]', i + 2);
      if (end > i + 2) {
        final inside = source.substring(i + 2, end);
        final parts = inside.split('|');
        final target = parts.first.trim();
        final label = parts.length > 1 ? parts[1].trim() : target;
        flush();
        final linkStyle = base.copyWith(
          color: ac.accent,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.underline,
          decorationColor: ac.accent,
        );
        if (onWikiLink == null) {
          spans.add(TextSpan(text: label, style: linkStyle));
        } else {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () => onWikiLink(target),
              child: Text(label, style: linkStyle),
            ),
          ));
        }
        i = end + 2;
        continue;
      }
    }

    // *斜体*（单个星号，且内容不以空格开头）
    if (ch == '*' && !source.startsWith('**', i) && i + 1 < source.length) {
      final end = source.indexOf('*', i + 1);
      if (end > i + 1 && source[i + 1] != ' ') {
        flush();
        spans.addAll(buildNatsumeInlineSpans(
          source.substring(i + 1, end),
          base: base.copyWith(fontStyle: FontStyle.italic),
          ac: ac,
          onWikiLink: onWikiLink,
          depth: depth + 1,
        ));
        i = end + 1;
        continue;
      }
    }

    buf.write(ch);
    i++;
  }
  flush();
  return spans;
}
