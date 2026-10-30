import 'package:flutter/material.dart';

import '../models/question_image.dart';
import '../utils/design_tokens.dart';

/// 配图全屏查看（双指缩放，点击任意处退出）。
///
/// 从 `natsume_rich_question_text.dart` 里抽出来的公共页：答题页、题目编辑
/// 弹窗、导入预览都要能「点缩略图看大图」，三处各写一份会出现转场/缩放手感
/// 不一致，Hero tag 也容易撞。
class QuestionImageViewerPage extends StatelessWidget {
  const QuestionImageViewerPage({
    super.key,
    required this.image,
    required this.heroTag,
  });

  final QuestionImage image;

  /// 与缩略图配对的 Hero tag（同题内稳定即可）
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 全屏看图需要中性纯黑压场，让图不受任何主题底色干扰——
      // 这是刻意脱离主题色板的媒体查看器惯例
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: Hero(
              tag: heroTag,
              child: Image.memory(image.content, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开配图全屏查看。
///
/// 统一使用「fade 先落位压住旧内容 + Hero 图同步飞入」的转场：进
/// [NatsumeMotion.slow] / 出 [NatsumeMotion.exit]，曲线统一 standard。
Future<void> openQuestionImageViewer(
  BuildContext context, {
  required QuestionImage image,
  required String heroTag,
}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: NatsumeMotion.effective(context, NatsumeMotion.slow),
    reverseTransitionDuration:
        NatsumeMotion.effective(context, NatsumeMotion.exit),
    transitionsBuilder: (context, animation, secondary, child) => FadeTransition(
      // fade 在窗口前段落定（先稳住黑场），Hero 飞行走满窗口
      opacity: CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.6, curve: NatsumeMotion.standard),
        reverseCurve: NatsumeMotion.standard,
      ),
      child: child,
    ),
    pageBuilder: (_, __, ___) =>
        QuestionImageViewerPage(image: image, heroTag: heroTag),
  ));
}
