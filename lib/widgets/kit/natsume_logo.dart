import 'package:flutter/material.dart';

/// 品牌标记：NatsumeQuizMaster 的角色图标。
///
/// 图标资源由 `assets/app_logo.png` 提供，与 Windows / Android 安装包使用
/// 同一份美术资源，避免桌面、启动器与应用内出现两套形象。
/// 外层按 [size] 的正方形裁切，并保持统一的圆角比例。
class NatsumeLogo extends StatelessWidget {
  const NatsumeLogo({super.key, this.size = 24, this.color});

  final double size;

  /// 图标加载失败时的兜底底色；正常加载时不影响原图。
  final Color? color;

  static const String assetName = 'assets/app_logo.png';

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: Image.asset(
            assetName,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => ColoredBox(
              color: color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );
}

/// 品牌标记（不垫底色、不加描边）。
///
/// 2026-10-07 真机反馈：此前这里会给标记垫一层描边方块（surfaceAlt 底 +
/// 1px 描边 + 内边距），于是启动页与首页问候卡上的标记被框住，实际绘制尺寸
/// 还要再扣掉内边距，看起来又小又闷。现在直接绘制标记本身，[box] 就是标记
/// 的实际边长，不再有承载它的那一层。
///
/// 若某处确实需要「有底色的方块」（例如背景与标记对比不足），请在该处自己
/// 包一层 [NatsumeSurface]，而不是让品牌标记固定带框。
class NatsumeLogoBadge extends StatelessWidget {
  const NatsumeLogoBadge({super.key, this.box = 34});

  /// 标记边长（不再是「外框边长」）。
  final double box;

  @override
  Widget build(BuildContext context) => NatsumeLogo(size: box);
}
