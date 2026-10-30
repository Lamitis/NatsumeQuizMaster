import 'package:flutter/material.dart';

import '../../models/companion.dart';
import '../../services/theme_service.dart';

/// 「小鲸」头像（v1.32）。
///
/// **为什么是自绘**：Coopanion 的 `web/whale/` 鲸鱼娘贴图明确不随其 AGPL
/// 授权（上游 THIRD_PARTY_NOTICES 原文要求「想在别处使用请自行确认原设与
/// 各家标志的权利」，围裙上还带 DeepSeek / OpenAI 等商标）。所以本工程
/// 不复用任何上游图片，改用 CustomPainter 现场绘制一只原创小鲸鱼娘：
/// 无外部资源、无网络、任意尺寸都清晰，也避免把别人的角色原设（溟月）
/// 与二创授权问题带进本仓库。
///
/// 表情由 [CompanionMood] 决定（与 `CompanionService` 的台词情绪同源），
/// 这样「说什么话配什么脸」是数据驱动的，不需要界面再猜。
class CompanionAvatar extends StatelessWidget {
  const CompanionAvatar({super.key, this.size = 72, this.mood = CompanionMood.idle});

  /// 头像边长（正方形）
  final double size;

  /// 当前情绪
  final CompanionMood mood;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Semantics(
      label: '小鲸头像 · ${mood.label}',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _WhaleGirlPainter(
            mood: mood,
            body: Color.lerp(ac.accent, ac.background, 0.55)!,
            belly: Color.lerp(ac.surfaceAlt, ac.accent, 0.18)!,
            line: ac.border,
            ink: ac.textPrimary,
            blush: ac.danger,
          ),
        ),
      ),
    );
  }
}

class _WhaleGirlPainter extends CustomPainter {
  _WhaleGirlPainter({
    required this.mood,
    required this.body,
    required this.belly,
    required this.line,
    required this.ink,
    required this.blush,
  });

  final CompanionMood mood;
  final Color body;
  final Color belly;
  final Color line;
  final Color ink;
  final Color blush;

  bool get _isGlad =>
      mood == CompanionMood.happy || mood == CompanionMood.proud;
  bool get _isCheering => mood == CompanionMood.cheer;
  bool get _isWorried => mood == CompanionMood.worried;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final s = size.shortestSide;
    final cx = w / 2;

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.018
      ..color = line
      ..isAntiAlias = true;
    final fill = Paint()..isAntiAlias = true;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.03
      ..color = ink
      ..isAntiAlias = true;

    // ── 头顶水花：开心/骄傲时喷一小朵 ──
    if (_isGlad) {
      fill.color = blush.withAlpha(150);
      final p = Path()
        ..moveTo(cx - s * 0.02, s * 0.20)
        ..quadraticBezierTo(cx - s * 0.11, s * 0.12, cx - s * 0.01, s * 0.05)
        ..quadraticBezierTo(cx + s * 0.09, s * 0.12, cx + s * 0.02, s * 0.20)
        ..close();
      canvas.drawPath(p, fill);
    }

    // ── 尾巴（右侧鳍）──
    final tail = Path()
      ..moveTo(cx + s * 0.28, s * 0.60)
      ..quadraticBezierTo(
          cx + s * 0.44, s * 0.52, cx + s * 0.42, s * 0.40)
      ..quadraticBezierTo(
          cx + s * 0.36, s * 0.50, cx + s * 0.26, s * 0.52)
      ..close();
    fill.color = body;
    canvas.drawPath(tail, fill);
    canvas.drawPath(tail, outline);

    // ── 身体（圆滚滚的鲸鱼头）──
    final bodyRect = Rect.fromCenter(
      center: Offset(cx, s * 0.64),
      width: s * 0.66,
      height: s * 0.52,
    );
    fill.color = body;
    canvas.drawOval(bodyRect, fill);
    canvas.drawOval(bodyRect, outline);

    // ── 肚皮（浅色月牙）──
    final bellyRect = Rect.fromCenter(
      center: Offset(cx, s * 0.72),
      width: s * 0.42,
      height: s * 0.28,
    );
    fill.color = belly;
    canvas.drawOval(bellyRect, fill);

    // ── 头顶小鳍 ──
    final fin = Path()
      ..moveTo(cx - s * 0.06, s * 0.40)
      ..quadraticBezierTo(cx, s * 0.30, cx + s * 0.08, s * 0.40)
      ..close();
    fill.color = body;
    canvas.drawPath(fin, fill);
    canvas.drawPath(fin, outline);

    // ── 眼睛：开心时弯成 ^ ^，其余是圆点；担心时加一道眉 ──
    final eyeY = s * 0.60;
    final eyeDx = s * 0.10;
    if (_isGlad) {
      for (final dir in [-1.0, 1.0]) {
        final p = Path()
          ..moveTo(cx + dir * eyeDx - s * 0.035, eyeY)
          ..quadraticBezierTo(
              cx + dir * eyeDx, eyeY - s * 0.045, cx + dir * eyeDx + s * 0.035, eyeY);
        canvas.drawPath(p, stroke);
      }
    } else {
      fill.color = ink;
      final r = _isWorried ? s * 0.022 : s * 0.028;
      canvas.drawCircle(Offset(cx - eyeDx, eyeY), r, fill);
      canvas.drawCircle(Offset(cx + eyeDx, eyeY), r, fill);
      if (_isWorried) {
        for (final dir in [-1.0, 1.0]) {
          final p = Path()
            ..moveTo(cx + dir * eyeDx - s * 0.035, eyeY - s * 0.065)
            ..lineTo(cx + dir * eyeDx + s * 0.035, eyeY - s * 0.085);
          canvas.drawPath(p, stroke);
        }
      }
    }

    // ── 腮红：开心与打气时露出来 ──
    if (_isGlad || _isCheering) {
      fill.color = blush.withAlpha(70);
      canvas.drawCircle(Offset(cx - s * 0.19, s * 0.70), s * 0.045, fill);
      canvas.drawCircle(Offset(cx + s * 0.19, s * 0.70), s * 0.045, fill);
    }

    // ── 嘴：担心时是一条平线，其余是向上的弧 ──
    final mouth = Path();
    if (_isWorried) {
      mouth
        ..moveTo(cx - s * 0.035, s * 0.73)
        ..lineTo(cx + s * 0.035, s * 0.73);
    } else {
      mouth
        ..moveTo(cx - s * 0.045, s * 0.71)
        ..quadraticBezierTo(cx, s * 0.77, cx + s * 0.045, s * 0.71);
    }
    canvas.drawPath(mouth, stroke);
  }

  @override
  bool shouldRepaint(covariant _WhaleGirlPainter old) =>
      old.mood != mood ||
      old.body != body ||
      old.belly != belly ||
      old.line != line ||
      old.ink != ink ||
      old.blush != blush;
}
