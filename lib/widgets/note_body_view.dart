import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';

/// 笔记正文预览：轻量 Markdown（标题 / 列表 / 粗体）+ 可点的 `[[双链]]`。
///
/// 为什么不直接用 `flutter_markdown`：它的 `onTapLink` 只认标准 Markdown 链接，
/// 要在渲染前把 `[[页]]` 改写成 `[页](note:页)`，还得自己处理 scheme 分发；
/// 笔记只需要标题/列表/粗体三件事，自己拼 [TextSpan] 反而更可控（也更好测）。
///
/// 点击双链交给 [onOpenLink]（目标页标题），由页面决定「打开已有笔记」
/// 还是「新建这一页」。
class NoteBodyView extends StatefulWidget {
  const NoteBodyView({
    super.key,
    required this.content,
    this.onOpenLink,
  });

  final String content;
  final void Function(String target)? onOpenLink;

  @override
  State<NoteBodyView> createState() => _NoteBodyViewState();
}

class _NoteBodyViewState extends State<NoteBodyView> {
  /// 本轮构建里的手势识别器：每帧重建会换新，旧的要显式 dispose，
  /// 否则每渲染一次泄漏一批 recognizer（长正文滚动时会明显涨内存）。
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    _disposeRecognizers();
    final lines = widget.content.isEmpty
        ? const ['']
        : widget.content.split('\n');
    final spans = <InlineSpan>[];
    for (final line in lines) {
      spans.addAll(_lineSpans(line, ac));
      spans.add(const TextSpan(text: '\n'));
    }
    return SelectionArea(
      child: Text.rich(
        TextSpan(children: spans),
        style: NatsumeType.bodyStyle
            .copyWith(color: ac.textPrimary, height: 1.7),
      ),
    );
  }

  /// 单行 → span 序列（标题加粗加大、`- ` 变项目符号）
  List<InlineSpan> _lineSpans(String raw, AppThemeColors ac) {
    var line = raw;
    double? sizeBoost;
    var bold = false;
    final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length;
      line = heading.group(2)!;
      bold = true;
      sizeBoost = level == 1 ? 4 : (level == 2 ? 2 : 0);
    } else if (RegExp(r'^\s*[-*+]\s+').hasMatch(line)) {
      line = '• ${line.replaceFirst(RegExp(r'^\s*[-*+]\s+'), '')}';
    } else if (line.startsWith('> ')) {
      line = line.substring(2);
    }

    final out = <InlineSpan>[];
    var cursor = 0;
    // 行内只解析两种标记：[[双链]] 与 **粗体**
    final pattern = RegExp(r'\[\[([^\[\]\n]+)\]\]|\*\*([^*\n]+)\*\*');
    for (final m in pattern.allMatches(line)) {
      if (m.start > cursor) {
        out.add(TextSpan(
          text: line.substring(cursor, m.start),
          style: _style(ac, bold: bold, sizeBoost: sizeBoost),
        ));
      }
      final bracket = m.group(1);
      if (bracket != null) {
        final target = bracket.split('|').first.trim();
        final label = bracket.split('|').length > 1
            ? bracket.split('|')[1].trim()
            : target;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onOpenLink?.call(target);
        _recognizers.add(recognizer);
        out.add(TextSpan(
          text: label,
          recognizer: recognizer,
          style: _style(ac, bold: true, sizeBoost: sizeBoost).copyWith(
            color: ac.accent,
            decoration: TextDecoration.underline,
            decorationColor: ac.accent,
          ),
        ));
      } else {
        out.add(TextSpan(
          text: m.group(2) ?? '',
          style:
              _style(ac, bold: true, sizeBoost: sizeBoost).copyWith(fontWeight: FontWeight.w600),
        ));
      }
      cursor = m.end;
    }
    if (cursor < line.length) {
      out.add(TextSpan(
        text: line.substring(cursor),
        style: _style(ac, bold: bold, sizeBoost: sizeBoost),
      ));
    }
    // 空行也要占一行高度
    if (out.isEmpty) out.add(const TextSpan(text: ''));
    return out;
  }

  TextStyle _style(AppThemeColors ac, {required bool bold, double? sizeBoost}) {
    final base = NatsumeType.bodyStyle.copyWith(color: ac.textPrimary);
    return base.copyWith(
      fontSize: base.fontSize == null ? null : base.fontSize! + (sizeBoost ?? 0),
      fontWeight: bold ? FontWeight.w600 : null,
    );
  }
}

/// 小工具：把正文里的双链目标提取出来给页面做跳转列表
List<String> noteLinkTargets(String content) => NoteLinks.extractTargets(content);
