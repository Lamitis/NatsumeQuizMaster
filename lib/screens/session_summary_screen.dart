import '../utils/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/quiz_session.dart';
import '../services/app_state.dart';
import '../services/theme_service.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/ai_response_widget.dart';
import '../utils/responsive.dart';
import 'quiz_screen.dart';

class SessionSummaryScreen extends StatefulWidget {
  final QuizSession session;

  const SessionSummaryScreen({super.key, required this.session});

  @override
  State<SessionSummaryScreen> createState() => _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends State<SessionSummaryScreen> {
  String? _summaryText;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _generateSummary();
  }

  Future<void> _generateSummary() async {
    final appState = context.read<AppState>();
    final summary = await appState.generateSessionSummary(widget.session);
    if (mounted) {
      setState(() {
        _summaryText = summary;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final accuracy = session.accuracy;
    final minutes = session.durationSeconds ~/ 60;
    final seconds = session.durationSeconds % 60;
    final ac = AppThemeColors.of(context);

    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('刷题小结'),
        automaticallyImplyLeading: false,
      ),
      // 平板适配：内容限宽居中（手机无影响）
      body: ResponsivePage(
        child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 成绩卡：平坦面板 + 左侧强调条 + 等宽大数字
            NatsumeSurface(
              accentEdge: true,
              padding: const EdgeInsets.all(NatsumeSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本次刷题完成',
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textSecondary)),
                  const SizedBox(height: NatsumeSpace.xs),
                  // 成绩读数滚动落位（等宽数字，滚动期间宽度不跳）
                  NatsumeAnimatedNumber(accuracy,
                      size: 44,
                      weight: FontWeight.w700,
                      suffix: '%',
                      decimals: 1,
                      color: ac.accent),
                  const SizedBox(height: NatsumeSpace.xxs),
                  // 标签是实义说明 → textSecondary（tertiary 只留占位/装饰）
                  Text('正确率',
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textSecondary)),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 详细统计
            Row(
              children: [
                Expanded(
                  child: _StatChip(
                    label: '总题量',
                    value: '${session.totalQuestions}',
                    color: ac.textPrimary,
                  ),
                ),
                const SizedBox(width: NatsumeSpace.xs),
                Expanded(
                  child: _StatChip(
                    label: '正确',
                    value: '${session.correctCount}',
                    // v1.0.2 设计审查修复：硬编码绿色 → 主题语义色
                    color: ac.success,
                  ),
                ),
                const SizedBox(width: NatsumeSpace.xs),
                Expanded(
                  child: _StatChip(
                    label: '错误',
                    value: '${session.wrongCount}',
                    color: ac.danger,
                  ),
                ),
                const SizedBox(width: NatsumeSpace.xs),
                Expanded(
                  child: _StatChip(
                    label: '用时',
                    value: '$minutes\'${seconds.toString().padLeft(2, '0')}"',
                    color: ac.textSecondary,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // AI 小结
            NatsumeSurface(
              padding: const EdgeInsets.all(NatsumeSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          color: ac.textSecondary, size: 16),
                      const SizedBox(width: NatsumeSpace.xs),
                      Text('AI 小结',
                          style: NatsumeType.h3Style.copyWith(
                              fontWeight: FontWeight.w600,
                              color: ac.textPrimary)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 生成中用呼吸骨架占位，生成完 120ms 淡切入场（减弱动态时直接落位）
                  AnimatedSwitcher(
                    duration: NatsumeMotion.effective(context, NatsumeMotion.fast),
                    switchInCurve: NatsumeMotion.standard,
                    child: _loading
                        ? const Column(
                            key: ValueKey('summary-loading'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              NatsumeSkeleton(width: double.infinity),
                              SizedBox(height: NatsumeSpace.xs),
                              NatsumeSkeleton(width: double.infinity),
                              SizedBox(height: NatsumeSpace.xs),
                              NatsumeSkeleton(width: 160),
                            ],
                          )
                        : AiResponseWidget(
                            key: const ValueKey('summary-text'),
                            text: _summaryText ?? '生成小结失败',
                            fontSize: NatsumeType.body,
                            color: ac.textPrimary,
                          ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            NatsumeButton(
              label: '返回首页',
              expand: true,
              onPressed: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
            const SizedBox(height: NatsumeSpace.xs),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  final appState = context.read<AppState>();
                  final nav = Navigator.of(context);
                  await appState.startQuiz();
                  if (appState.quizQuestions.isEmpty) return;
                  if (!mounted) return;
                  nav.pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const QuizScreen()),
                  );
                },
                child: const Text('再来一轮', style: TextStyle(fontSize: NatsumeType.h3)),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 统计小格：精密面板 + 等宽数字（图标已由标签语义取代，减少视觉噪音）。
class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return NatsumeSurface(
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.xs, vertical: NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标签是实义说明 → textSecondary（tertiary 只留占位/装饰）
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NatsumeType.microStyle.copyWith(color: ac.textSecondary)),
          const SizedBox(height: NatsumeSpace.xxs + 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NatsumeType.number(NatsumeType.h3, weight: FontWeight.w700)
                  .copyWith(color: color)),
        ],
      ),
    );
  }
}
