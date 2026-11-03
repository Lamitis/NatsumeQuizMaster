import 'package:flutter/material.dart';

import '../services/debug_log_service.dart';
import 'markdown/natsume_markdown.dart';

/// AI 回复 / 解析的富文本渲染器（v1.40 起由 [NatsumeMarkdown] 统一承担）。
///
/// 历史沿革：v1.0.2 因 `flutter_markdown` 对「中文全角标点紧跟闭合星号」
/// 解析失败，改成自研 span 渲染器；v1.28 加结构色（答案/题眼/解析/
/// 避坑指南/一句话记忆）；v1.40 把渲染能力下沉到
/// `lib/widgets/markdown/natsume_markdown.dart`，本组件只剩两件事：
///
/// 1. **零宽字符清洗**：模型偶发返回 `\u200B/\u200C/\u200D`，粘进
///    `TextSpan` 会出现「看不见但会撑宽」的怪排版，先洗掉再渲染；
/// 2. **AI 结构色开关**：解析卡里的「答案：」等标签要染色，
///    而笔记正文不该被系统染色，所以由这里显式打开 `aiSections`。
///
/// 渲染能力（LaTeX / 表格 / 代码高亮 / `<mark>` / `<span style>`）
/// 全部来自共享引擎，刷题页题干、选项、AI 解析与笔记正文因此观感一致。
class AiResponseWidget extends StatelessWidget {
  final String text;
  final double fontSize;
  final Color? color;

  const AiResponseWidget({
    super.key,
    required this.text,
    this.fontSize = 13,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return NatsumeMarkdown(
      text: _sanitize(text),
      fontSize: fontSize,
      color: color,
      aiSections: true,
    );
  }

  String _sanitize(String raw) {
    final result = raw
        .replaceAll('\u200B', '')
        .replaceAll('\u200C', '')
        .replaceAll('\u200D', '');
    final logger = DebugLogService.instance;
    final removed = raw.length - result.length;
    if (removed > 0) {
      logger.logSanitize(raw.length, result.length, removed);
    }
    return result;
  }
}
