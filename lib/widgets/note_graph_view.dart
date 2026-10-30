import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import 'kit/natsume_kit.dart';

/// 双链笔记图谱（Graph）· 本地极简实现。
///
/// 取形于 Logseq 的 Graph 视图：一个节点一页笔记，一条线一次引用。
/// 不引物理引擎（包体/性能都不划算），用**同心环布局**：
/// 度数高的节点在内环、低的在外环，节点位置只由「排序后的序号」决定，
/// 同一份数据每次渲染位置稳定，用户不会看见图在抖。
///
/// 只被引用、尚未写过的页面（悬空页）用虚线描边表示，点它可新建。
class NoteGraphView extends StatelessWidget {
  const NoteGraphView({
    super.key,
    required this.graph,
    this.onTapNode,
  });

  final NoteGraph graph;

  /// 点节点回调（打开对应笔记 / 新建悬空页）
  final void Function(NoteNode node)? onTapNode;

  /// 每环最多放几个节点：太多会挤成一圈看不清
  static const int _perRing = 8;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    if (graph.isEmpty) {
      return const NatsumeEmptyState(
        icon: Icons.hub_outlined,
        title: '还没有可连线的笔记',
        description: '笔记正文里写 [[另一页]] 或 #标签，这里就会长出节点和连线',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : w;
        final size = Size(w, h);
        final positions = _layout(size, graph.nodes);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final node = _hitTest(positions, details.localPosition);
            if (node != null) onTapNode?.call(node);
          },
          child: CustomPaint(
            size: size,
            painter: _GraphPainter(
              graph: graph,
              positions: positions,
              ac: ac,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        );
      },
    );
  }

  /// 同心环布局：节点已按度数倒序，序号决定环与角度
  Map<String, Offset> _layout(Size size, List<NoteNode> nodes) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius =
        math.max(40.0, math.min(size.width, size.height) / 2 - 36);
    final out = <String, Offset>{};
    for (var i = 0; i < nodes.length; i++) {
      if (i == 0) {
        out[nodes[i].id] = center;
        continue;
      }
      // i=1.._perRing → 第 1 环；以此类推
      final ring = (i - 1) ~/ _perRing + 1;
      final indexInRing = (i - 1) % _perRing;
      final rings = ((nodes.length - 1) / _perRing).ceil();
      final radius = maxRadius * ring / math.max(1, rings);
      final countInRing =
          math.min(_perRing, nodes.length - 1 - (ring - 1) * _perRing);
      // 每环错开半格，避免所有节点排成一条射线
      final angle =
          (indexInRing / countInRing) * 2 * math.pi + (ring.isEven ? 0.35 : 0);
      out[nodes[i].id] = center +
          Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    }
    return out;
  }

  NoteNode? _hitTest(Map<String, Offset> positions, Offset point) {
    NoteNode? best;
    var bestDist = 22.0; // 命中半径（手指触摸友好）
    for (final node in graph.nodes) {
      final p = positions[node.id];
      if (p == null) continue;
      final d = (p - point).distance;
      if (d <= bestDist) {
        bestDist = d;
        best = node;
      }
    }
    return best;
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.graph,
    required this.positions,
    required this.ac,
    required this.textScaler,
  });

  final NoteGraph graph;
  final Map<String, Offset> positions;
  final AppThemeColors ac;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = ac.border
      ..strokeWidth = NatsumeLine.width
      ..style = PaintingStyle.stroke;

    for (final e in graph.edges) {
      final a = positions[e.from];
      final b = positions[e.to];
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, edgePaint);
    }

    for (final node in graph.nodes) {
      final p = positions[node.id];
      if (p == null) continue;
      final radius = node.degree >= 4
          ? 7.0
          : node.degree >= 2
              ? 5.5
              : 4.0;
      final fill = Paint()
        ..color = node.missing ? ac.surface : ac.accent
        ..style = node.missing ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = NatsumeLine.width;
      canvas.drawCircle(p, radius, fill);
      _paintLabel(canvas, size, p + Offset(0, radius + 2), node.id, node.missing);
    }
  }

  void _paintLabel(
      Canvas canvas, Size size, Offset anchor, String text, bool missing) {
    final tp = TextPainter(
      text: TextSpan(
        text: text.length > 10 ? '${text.substring(0, 10)}…' : text,
        style: TextStyle(
          fontSize: 10,
          color: missing ? ac.textTertiary : ac.textSecondary,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '…',
      textScaler: textScaler,
    )..layout(maxWidth: 96);
    // 居中到节点下方，并夹在画布内
    final dx = (anchor.dx - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width));
    final dy = anchor.dy.clamp(0.0, math.max(0.0, size.height - tp.height));
    tp.paint(canvas, Offset(dx.toDouble(), dy.toDouble()));
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.graph != graph || old.ac != ac;
}
