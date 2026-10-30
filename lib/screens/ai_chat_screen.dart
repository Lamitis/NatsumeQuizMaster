import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/follow_up_message.dart';
import '../models/question.dart';
import '../services/app_state.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../widgets/ai_response_widget.dart';

/// AI 对话页（Natsume Des · v1.28 重做）
///
/// 旧版把追问聊天嵌在「AI 解析」卡片里：空间局促、要滚很久才看得到、
/// 气泡宽度写死 280、没有独立对话空间。现改为**全屏对话页**：
/// 顶部题目上下文卡 → 可滚动消息流 → 底部固定输入栏（键盘弹出自动上移）。
///
/// 数据仍走 AppState.followUpHistory / sendFollowUp（按题持久化，切题不串）。
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  bool _inited = false;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final app = context.read<AppState>();
    try {
      // 追问需要解析作为上下文：未加载则先拉取（含缓存/生成）
      if (app.currentAnalysis == null || app.currentAnalysis!.isEmpty) {
        await app.showAnalysis();
      } else {
        await app.loadFollowUpHistory();
      }
    } catch (e) {
      // 初始化失败不阻塞进入（输入栏仍可用，发送时会再取上下文）
      debugPrint('AiChatScreen init failed: $e');
    }
    if (!mounted) return;
    setState(() => _inited = true);
    _scrollToBottom(animated: false);
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animated) {
        _scroll.animateTo(target,
            duration: NatsumeMotion.normal, curve: NatsumeMotion.standard);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  Future<void> _send() async {
    final app = context.read<AppState>();
    if (!app.settings.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: const Text('请先在设置中配置 API Key 后再追问。'),
            backgroundColor: AppThemeColors.of(context).warning),
      );
      return;
    }
    final text = _input.text.trim();
    if (text.isEmpty || app.followUpLoading) return;
    _input.clear();
    _scrollToBottom();
    await app.sendFollowUp(text);
    if (!mounted) return;
    _scrollToBottom();
  }

  Future<void> _clear() async {
    final ac = AppThemeColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空对话'),
        content: const Text('将删除这道题的全部追问记录，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ac.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().clearFollowUpHistory();
    if (!mounted) return;
    setState(() {});
  }

  /// 开关「解析 / 追问引用知识库」（v1.34）。
  ///
  /// 这里只是**软约束**：资料优先、没覆盖的部分仍由 AI 自己补（用户明确要求
  /// 「不完全依赖知识库，因为知识库不一定全面」）。
  Future<void> _toggleGrounding() async {
    final app = context.read<AppState>();
    final on = !app.settings.analysisGrounding;
    await app.setAnalysisGrounding(on);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(on
          ? '已开启知识库引用：资料优先，资料没覆盖的部分仍由 AI 补充'
          : '已关闭知识库引用：解析与追问只走 AI 自身知识'),
      duration: NatsumeMotion.toast,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final app = context.watch<AppState>();
    final q = app.currentQuestion;
    final history = app.followUpHistory;

    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('AI 助手'),
            if (q != null)
              Text(
                '第 ${app.currentQuestionIndex + 1} 题 · ${q.typeLabel}',
                style: NatsumeType.microStyle.copyWith(
                    color: ac.textTertiary, fontWeight: FontWeight.w400),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip:
                app.settings.analysisGrounding ? '知识库引用：开' : '知识库引用：关',
            icon: Icon(app.settings.analysisGrounding
                ? Icons.menu_book_rounded
                : Icons.menu_book_outlined),
            onPressed: app.settings.isConfigured ? _toggleGrounding : null,
          ),
          if (history.isNotEmpty)
            IconButton(
              tooltip: '清空对话',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clear,
            ),
        ],
      ),
      body: !_inited
          ? Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: ac.accent),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                        NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, NatsumeSpace.sm),
                    children: [
                      if (q != null) _QuestionContextCard(question: q, ac: ac),
                      // v1.34：这次解析真的用上了知识库资料就明说，
                      // 免得用户以为「引用了资料」和「没引用」长得一样
                      if (app.analysisGrounded) ...[
                        const SizedBox(height: NatsumeSpace.xs),
                        Row(
                          children: [
                            Icon(Icons.fact_check_outlined,
                                size: 14, color: ac.success),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '本次解析引用了已导入的知识库（资料优先，未覆盖部分由 AI 补充）',
                                style: NatsumeType.microStyle
                                    .copyWith(color: ac.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: NatsumeSpace.md),
                      if (history.isEmpty && !app.followUpLoading)
                        _EmptyState(
                            ac: ac,
                            onPick: (t) {
                              _input.text = t;
                              _focus.requestFocus();
                            })
                      else
                        for (final m in history)
                          _ChatBubble(message: m, ac: ac),
                      // 流式输出：已经有内容就渲染进行中的气泡（边生成边显示），
                      // 还没有首个 chunk 时仍用三点等待指示。
                      // 气泡组件复用 _ChatBubble（它渲染的是传入文本，文本变长即重绘）。
                      if (app.followUpLoading && app.streamingReply.isNotEmpty)
                        _ChatBubble(
                          message: FollowUpMessage(
                              role: 'assistant', content: app.streamingReply),
                          ac: ac,
                        )
                      else if (app.followUpLoading)
                        _TypingBubble(ac: ac),
                    ],
                  ),
                ),
                _InputBar(
                  controller: _input,
                  focus: _focus,
                  enabled: app.settings.isConfigured && !app.followUpLoading,
                  ac: ac,
                  onSend: _send,
                ),
              ],
            ),
    );
  }
}

/// 题目上下文卡：让用户始终知道"在问哪道题"
class _QuestionContextCard extends StatefulWidget {
  const _QuestionContextCard({required this.question, required this.ac});

  final Question question;
  final AppThemeColors ac;

  @override
  State<_QuestionContextCard> createState() => _QuestionContextCardState();
}

class _QuestionContextCardState extends State<_QuestionContextCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ac = widget.ac;
    final q = widget.question;
    return Container(
      padding: const EdgeInsets.all(NatsumeSpace.sm + 2),
      decoration: BoxDecoration(
        color: ac.surface,
        borderRadius: NatsumeRadius.controlBorder,
        border: Border.all(color: ac.border, width: NatsumeShadow.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.article_outlined, size: 16, color: ac.accent),
              const SizedBox(width: NatsumeSpace.xs - 2),
              Text('当前题目',
                  style: NatsumeType.microStyle.copyWith(color: ac.accent)),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(NatsumeRadius.chip),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: ac.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xs - 2),
          Text(
            q.title,
            maxLines: _expanded ? 12 : 2,
            overflow: TextOverflow.ellipsis,
            style: NatsumeType.captionStyle
                .copyWith(color: ac.textPrimary, height: 1.55),
          ),
          if (_expanded && q.options.isNotEmpty) ...[
            const SizedBox(height: NatsumeSpace.xs - 2),
            for (var i = 0; i < q.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${String.fromCharCode(65 + i)}. ${q.options[i]}',
                  style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary),
                ),
              ),
          ],
          const SizedBox(height: NatsumeSpace.xxs + 2),
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 14, color: ac.success),
              const SizedBox(width: 4),
              Text('答案 ${q.correctAnswer}',
                  style: NatsumeType.microStyle.copyWith(color: ac.success)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 空态：引导 + 快捷提问（降低首次使用门槛）
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.ac, required this.onPick});

  final AppThemeColors ac;
  final ValueChanged<String> onPick;

  static const _quick = [
    '这道题的解题思路是什么？',
    '其他选项为什么错？',
    '帮我梳理相关的知识点',
    '举个实际例子帮助理解',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: NatsumeSpace.xl),
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: ac.accentSoft,
            borderRadius: NatsumeRadius.controlBorder,
          ),
          child: Icon(Icons.forum_outlined, size: 26, color: ac.accent),
        ),
        const SizedBox(height: NatsumeSpace.sm),
        Text('有什么不懂的，直接问',
            style:
                NatsumeType.h3Style.copyWith(color: ac.textPrimary, fontSize: 15)),
        const SizedBox(height: NatsumeSpace.xxs),
        Text('AI 会结合上面的解析与题目上下文回答',
            textAlign: TextAlign.center,
            style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
        const SizedBox(height: NatsumeSpace.lg),
        Wrap(
          spacing: NatsumeSpace.xs,
          runSpacing: NatsumeSpace.xs,
          alignment: WrapAlignment.center,
          children: [
            for (final t in _quick)
              InkWell(
                borderRadius: BorderRadius.circular(NatsumeRadius.control),
                onTap: () => onPick(t),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NatsumeSpace.sm + 2, vertical: NatsumeSpace.xs),
                  decoration: BoxDecoration(
                    color: ac.surface,
                    borderRadius: BorderRadius.circular(NatsumeRadius.control),
                    border:
                        Border.all(color: ac.border, width: NatsumeShadow.hairline),
                  ),
                  child: Text(t,
                      style:
                          NatsumeType.captionStyle.copyWith(color: ac.textPrimary)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 对话气泡：用户右侧（强调色）/ AI 左侧（surface + 图标）
class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message, required this.ac});

  final FollowUpMessage message;
  final AppThemeColors ac;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final maxW = MediaQuery.sizeOf(context).width * 0.76;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm + 2, vertical: NatsumeSpace.xs + 2),
      decoration: BoxDecoration(
        color: isUser ? ac.accent : ac.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(NatsumeRadius.control),
          topRight: const Radius.circular(NatsumeRadius.control),
          bottomLeft: Radius.circular(isUser ? NatsumeRadius.control : 5),
          bottomRight: Radius.circular(isUser ? 5 : NatsumeRadius.control),
        ),
        border: isUser
            ? null
            : Border.all(color: ac.border, width: NatsumeShadow.hairline),
      ),
      child: isUser
          ? Text(message.content,
              style:
                  NatsumeType.bodyStyle.copyWith(color: ac.onAccent, height: 1.5))
          : AiResponseWidget(text: message.content, fontSize: NatsumeType.body - 1),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: NatsumeSpace.sm + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: ac.accentSoft,
                borderRadius: BorderRadius.circular(NatsumeRadius.chip + 2),
              ),
              child: Icon(Icons.auto_awesome, size: 14, color: ac.accent),
            ),
            const SizedBox(width: NatsumeSpace.xs),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: bubble,
          ),
        ],
      ),
    );
  }
}

/// AI 回复中（三点跳动）
class _TypingBubble extends StatefulWidget {
  const _TypingBubble({required this.ac});

  final AppThemeColors ac;

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = widget.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: NatsumeSpace.sm + 2),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: ac.accentSoft,
              borderRadius: BorderRadius.circular(NatsumeRadius.chip + 2),
            ),
            child: Icon(Icons.auto_awesome, size: 14, color: ac.accent),
          ),
          const SizedBox(width: NatsumeSpace.xs),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: NatsumeSpace.sm + 2, vertical: NatsumeSpace.sm),
            decoration: BoxDecoration(
              color: ac.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(NatsumeRadius.control),
                topRight: Radius.circular(NatsumeRadius.control),
                bottomLeft: Radius.circular(5),
                bottomRight: Radius.circular(NatsumeRadius.control),
              ),
              border: Border.all(color: ac.border, width: NatsumeShadow.hairline),
            ),
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                      child: Opacity(
                        opacity: 0.35 +
                            0.65 *
                                ((1 - ((_c.value - i * 0.18).abs() % 0.5) / 0.5)
                                    .clamp(0.0, 1.0)),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: ac.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部输入栏：多行自适应输入 + 圆形发送按钮
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.ac,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool enabled;
  final AppThemeColors ac;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          NatsumeSpace.md, NatsumeSpace.xs, NatsumeSpace.md, NatsumeSpace.sm),
      decoration: BoxDecoration(
        color: ac.surface,
        border: Border(
            top: BorderSide(color: ac.border, width: NatsumeShadow.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: enabled ? '继续追问…' : 'AI 正在回复…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: NatsumeSpace.sm + 2, vertical: NatsumeSpace.sm),
                ),
                style: NatsumeType.bodyStyle.copyWith(color: ac.textPrimary),
              ),
            ),
            const SizedBox(width: NatsumeSpace.xs),
            _SendButton(enabled: enabled, ac: ac, onTap: onSend),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.ac,
    required this.onTap,
  });

  final bool enabled;
  final AppThemeColors ac;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? ac.accent : ac.surfaceAlt,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(
            Icons.arrow_upward_rounded,
            size: 20,
            color: enabled ? ac.onAccent : ac.textTertiary,
          ),
        ),
      ),
    );
  }
}
