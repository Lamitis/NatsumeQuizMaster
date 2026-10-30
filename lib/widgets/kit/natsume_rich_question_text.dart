import 'package:flutter/material.dart';

import '../../models/question_image.dart';
import '../../services/theme_service.dart';
import '../../utils/design_tokens.dart';
import '../../utils/question_image_tokens.dart';
import '../question_image_viewer.dart';

/// 题目图文混排文本：把含 `{{img:N}}` 占位符的题目文本渲染为
/// 「文字段 ↔ 图片」交替的内容流。
///
/// 图片是题目内容的一部分——出现在占位符所在的阅读位置，随题显示；
/// 槽位缺图时显示「图片缺失」占位块（显式可见，绝不静默丢图）。
class NatsumeRichQuestionText extends StatelessWidget {
  const NatsumeRichQuestionText({
    super.key,
    required this.text,
    this.images = const [],
    this.style,
    this.textBuilder,
    this.heroGroup,
  });

  /// 题目文本（可含 `{{img:N}}` 占位符）
  final String text;

  /// 该题配图（按 position 对应占位符）
  final List<QuestionImage> images;

  /// 文字段样式（缺省用主题正文）
  final TextStyle? style;

  /// 文字段渲染器（缺省 [Text]）；解析区可换成 markdown 渲染器，
  /// 图片段照样插在文本段之间
  final Widget Function(BuildContext context, String text)? textBuilder;

  /// Hero 分组（同题内稳定的标识，如题号）：图片查看的 Hero tag 默认
  /// `qimg-$slot`（同题内稳定）；一屏渲染多道题时（如导入预览列表）必须
  /// 传入各题唯一的 [heroGroup]，否则同槽位 tag 相同会触发 Flutter 的
  /// 「multiple heroes that share the same tag」断言。
  final String? heroGroup;

  @override
  Widget build(BuildContext context) {
    final segments = splitByImageTokens(text);
    final hasImage = segments.any((s) => s is QuestionImageSlot);
    if (!hasImage) return _buildText(context, text);

    final children = <Widget>[];
    for (final seg in segments) {
      if (seg is QuestionTextRun) {
        if (seg.text.trim().isNotEmpty) {
          children.add(_buildText(context, seg.text));
          children.add(const SizedBox(height: NatsumeSpace.xs));
        }
      } else if (seg is QuestionImageSlot) {
        children.add(_QuestionImageBlock(
            slot: seg.slot, images: images, heroGroup: heroGroup));
        children.add(const SizedBox(height: NatsumeSpace.xs));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildText(BuildContext context, String value) =>
      textBuilder?.call(context, value) ?? Text(value, style: style);
}

class _QuestionImageBlock extends StatelessWidget {
  const _QuestionImageBlock(
      {required this.slot, required this.images, this.heroGroup});

  final int slot;
  final List<QuestionImage> images;
  final String? heroGroup;

  /// 同题内稳定、可跨题区分的 Hero tag
  String get _tag => heroGroup == null ? 'qimg-$slot' : 'qimg-$heroGroup-$slot';

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    QuestionImage? img;
    for (final i in images) {
      if (i.position == slot) {
        img = i;
        break;
      }
    }
    if (img == null || img.content.isEmpty) return _missing(ac);

    return GestureDetector(
      onTap: () => openQuestionImageViewer(context, image: img!, heroTag: _tag),
      child: Hero(
        tag: _tag,
        child: ClipRRect(
          borderRadius: NatsumeRadius.cardBorder,
          child: Image.memory(
            img.content,
            fit: BoxFit.contain,
            width: double.infinity,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _missing(ac),
          ),
        ),
      ),
    );
  }

  /// 槽位缺图：显式占位块（图片本应是题目的一部分，缺了必须看得见）
  Widget _missing(AppThemeColors ac) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      decoration: BoxDecoration(
        border: Border.all(color: ac.border),
        borderRadius: NatsumeRadius.cardBorder,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined, size: 16, color: ac.textTertiary),
          const SizedBox(width: 6),
          Text('图片缺失',
              style: NatsumeType.captionStyle.copyWith(color: ac.textTertiary)),
        ],
      ),
    );
  }
}
