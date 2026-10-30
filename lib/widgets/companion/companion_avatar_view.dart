import 'package:flutter/material.dart';

import '../../models/companion.dart';
import '../../models/companion_avatar.dart';
import '../../models/companion_settings.dart';
import 'companion_avatar.dart';

/// 助教形象（v1.35）：一处决定「用哪张图」，浮层、角色卡、气泡、设置页预览共用。
///
/// 默认项刻意仍用 v1.32 的 [CompanionAvatar] 自绘头像：那是不依赖任何素材的
/// 兜底形态，图片缺失/解码失败时也退到它，浮层不会变成一块空白。
/// 选了官方插件里的角色（`assets/plugins/official/companion/avatars/*.png`）
/// 才换成图片。
class CompanionAvatarView extends StatelessWidget {
  const CompanionAvatarView({
    super.key,
    required this.settings,
    this.size = 64,
    this.mood = CompanionMood.idle,
  });

  final CompanionSettings settings;

  /// 边长（正方形）
  final double size;

  /// 默认自绘头像用的情绪（选图片时忽略）
  final CompanionMood mood;

  @override
  Widget build(BuildContext context) {
    final option = settings.avatarOption;
    if (option.id == CompanionAvatarOption.defaultId) {
      return CompanionAvatar(mood: mood, size: size);
    }
    return Semantics(
      label: '${settings.displayName}助教形象 · ${option.label}',
      image: true,
      child: ClipRRect(
        // 头像卡片的圆角取边长的 22%：小尺寸（28px 气泡头像）也不会变成方块
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset(
          option.asset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          // 资产没打进包（自定义构建裁剪过 assets）也不崩：退回自绘头像
          errorBuilder: (_, __, ___) => CompanionAvatar(mood: mood, size: size),
        ),
      ),
    );
  }
}
