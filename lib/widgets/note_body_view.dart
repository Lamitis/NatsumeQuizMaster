import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import 'markdown/natsume_markdown.dart';

/// 笔记正文预览（v1.40：统一走 [NatsumeMarkdown]）。
///
/// 旧实现自己拼 [TextSpan]，只认标题 / 列表 / 粗体三件事；v1.40 起笔记
/// 与 AI 解析共用同一套渲染引擎，于是工科笔记里的
/// `$\ce{H2O}$`、```dart 代码块、GFM 表格、`<mark>` / `<span style>` 
/// 都能直接显示——工具栏写进去的标记也能立刻在「预览」里看到效果。
///
/// 与 AI 解析的唯一差别是 `aiSections: false`：笔记的「答案：」不是
/// 系统结构标签，不该被自动染色。`[[双链]]` 仍然可点，由 [onOpenLink]
/// 决定「打开已有笔记」还是「新建这一页」。
class NoteBodyView extends StatelessWidget {
  const NoteBodyView({
    super.key,
    required this.content,
    this.onOpenLink,
  });

  final String content;
  final void Function(String target)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return NatsumeMarkdown(
      text: content,
      style: NatsumeType.bodyStyle.copyWith(color: ac.textPrimary, height: 1.7),
      onWikiLink: onOpenLink,
      // 预览区允许选中复制（旧实现也是 SelectionArea）
      selectable: true,
    );
  }
}

/// 小工具：把正文里的双链目标提取出来给页面做跳转列表
List<String> noteLinkTargets(String content) => NoteLinks.extractTargets(content);
