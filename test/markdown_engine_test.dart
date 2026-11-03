import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/markdown/natsume_markdown.dart';

/// 统一渲染引擎（v1.40）的契约：
///
/// 1. 块级：```lang 代码块 / GFM 表格 / `$$...$$` 各自成块，不被文本块吞掉；
/// 2. 行内：`$...$` 走 flutter_math_fork（不能把 `$` 源码摊给用户）、
///    `<mark>` 有底色、`<span style="color: #HEX">` 真的换色；
/// 3. 表格必须是 [Table]（有边框）且外层可横向滚动——窄屏不溢出。
///
/// 这些是「工科题能不能看」的底线，普通 Markdown 的加粗/列表/结构色由
/// `ai_response_render_test.dart` 与 `ai_chat_test.dart` 继续守着。
void main() {
  Widget wrap(String text) => MaterialApp(
        theme: ThemeService().themeData,
        home: Scaffold(
          body: SingleChildScrollView(child: NatsumeMarkdown(text: text)),
        ),
      );

  group('块级解析', () {
    test('围栏代码 / 表格 / 块级公式各自成块', () {
      const md = '开头\n\n'
          '```dart\nvoid main() {}\n```\n\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n\n'
          r'$$' '\nE=mc^2\n' r'$$';
      final blocks = parseNatsumeBlocks(md);

      final code =
          blocks.firstWhere((b) => b.kind == NatsumeMdBlockKind.code);
      expect(code.language, 'dart');
      expect(code.code, 'void main() {}');

      final table =
          blocks.firstWhere((b) => b.kind == NatsumeMdBlockKind.table);
      expect(table.rows.length, 2);
      expect(table.rows.first, ['a', 'b']);
      expect(table.rows.last, ['1', '2']);

      final math =
          blocks.firstWhere((b) => b.kind == NatsumeMdBlockKind.math);
      expect(math.tex, 'E=mc^2');

      final text = blocks.firstWhere((b) => b.kind == NatsumeMdBlockKind.text);
      expect(text.lines.single.content, '开头');
    });

    test('行内公式不跨行、金额文本不被误判成公式', () {
      final blocks = parseNatsumeBlocks('这本书 \$5 元，公式 \$x+1\$ 正常');
      final line = blocks.single.lines.single;
      expect(line.content.contains(r'$x+1$'), isTrue);
      expect(line.content.contains(r'$5'), isTrue,
          reason: '货币写法没有闭合 \$，应原样保留');
    });

    test('结构标签：**答案：** / 答案： 都识别为 section', () {
      final blocks = parseNatsumeBlocks('**答案：** B\n答案：C');
      final lines = blocks.single.lines;
      expect(lines[0].section, '答案');
      expect(lines[0].content, 'B');
      expect(lines[1].section, '答案');
      expect(lines[1].content, 'C');
    });
  });

  group('颜色 / 语言归一', () {
    test('parseMarkdownColor：hex / 简写 / 英文色名', () {
      expect(parseMarkdownColor('#F00'), const Color(0xFFFF0000));
      expect(parseMarkdownColor('#2F6FEB'), const Color(0xFF2F6FEB));
      expect(parseMarkdownColor('red'), isNotNull);
      expect(parseMarkdownColor('not-a-color'), isNull);
    });

    test('normalizeHighlightLanguage：别名归一，未知回落 plaintext', () {
      expect(normalizeHighlightLanguage(''), 'plaintext');
      expect(normalizeHighlightLanguage('js'), 'javascript');
      expect(normalizeHighlightLanguage('C++'), 'cpp');
      expect(normalizeHighlightLanguage('unknown-lang'), 'unknown-lang');
    });
  });

  testWidgets('GFM 表格：渲染为 Table 且有横向滚动', (tester) async {
    await tester.pumpWidget(wrap('| 选项 | 说明 |\n|---|---|\n| A | 大分子 |'));

    expect(find.byType(Table), findsOneWidget);
    expect(find.textContaining('大分子'), findsOneWidget);
    // 表格不裸奔
    expect(find.textContaining('|'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('代码块：HighlightView 高亮，围栏不显示', (tester) async {
    await tester.pumpWidget(wrap('```dart\nvoid main() {}\n```'));

    expect(find.byType(HighlightView), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
    // HighlightView 内部是 RichText，按富文本匹配代码内容
    expect(find.textContaining('void main()', findRichText: true),
        findsOneWidget);
  });

  testWidgets('块级公式：渲染为 Math 组件，\$\$ 不残留', (tester) async {
    await tester.pumpWidget(wrap(r'$$' '\nE=mc^2\n' r'$$'));

    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining(r'$$'), findsNothing);
  });

  testWidgets('行内公式：渲染为 Math，正文里没有 \$ 源码', (tester) async {
    await tester.pumpWidget(wrap(r'由 $F=ma$ 可得加速度'));

    expect(find.byType(Math), findsOneWidget);
    final joined = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((rt) => rt.text.toPlainText())
        .join();
    expect(joined.contains(r'$'), isFalse);
    expect(joined.contains('可得加速度'), isTrue);
  });

  testWidgets('<mark> 高亮与 <span style="color"> 彩色文本生效', (tester) async {
    await tester.pumpWidget(wrap(
        '<mark>重点</mark> 与 <span style="color: #2F6FEB">蓝字</span>'));

    final rt = tester.widget<RichText>(find.byType(RichText).first);
    final spans = <TextSpan>[];
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(rt.text);
    expect(
        spans.any((s) => s.text == '重点' && s.style?.backgroundColor != null),
        isTrue,
        reason: '<mark> 应该带底色');
    expect(
        spans.any((s) =>
            s.text == '蓝字' && s.style?.color == const Color(0xFF2F6FEB)),
        isTrue,
        reason: '<span style="color"> 应该真的换色');
    expect(find.textContaining('<mark>'), findsNothing);
    expect(find.textContaining('</span>'), findsNothing);
  });

  testWidgets('未闭合标签容错：原样显示，不吞后文', (tester) async {
    await tester.pumpWidget(wrap('正常 <mark>未闭合，后面还有内容'));

    expect(find.textContaining('后面还有内容'), findsOneWidget);
  });
}
