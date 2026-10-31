import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/companion.dart';
import '../models/companion_memory.dart';
import '../models/companion_settings.dart';
import '../models/plugin_sync_scope.dart';
import '../services/ai_service.dart';
import '../services/app_state.dart';
import '../services/companion/companion_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/companion/companion_avatar_view.dart';
import '../widgets/kit/natsume_kit.dart';
import 'companion_settings_screen.dart';

/// 「小鲸助教」陪伴页（v1.32 · 内置插件 `natsume.companion`）。
///
/// 第二个插件是 AI bot：参考 Coopanion 的陪伴感，用鲸鱼娘形象鼓励学习。
/// 落地时的三条自我约束：
///
/// 1. **数字必须是真的**：连胜 / 今日题量 / 本周正确率 / 错题到期全部来自
///    本机统计，AI 只被允许复述这些数字（`CompanionService.buildPrompt`），
///    杜绝「bot 夸你连了 30 天、首页显示 2 天」这种幻觉型鼓励；
/// 2. **没配 API Key 也能用**：脚本台词 + 关键词兜底永远在线，AI 只是增强；
/// 3. **同步边界说清楚**：人设与记忆可同步（设置可关），API Key 与好感度只留本机，
///    与双链笔记同一口径。
class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key});

  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  CompanionSnapshot _snapshot = CompanionSnapshot.empty;
  CompanionState _state = CompanionState.empty;
  CompanionMood _mood = CompanionMood.idle;

  /// 助教设置（v1.35：形象也来自这里，改完设置回来自动刷新）
  CompanionSettings _settings = CompanionSettings.defaults;

  final List<_ChatMessage> _messages = [];

  /// v1.33 记忆：最近 40 轮 + 客观摘要，进入页面时回填到最后几条
  CompanionMemory _memory = CompanionMemory();

  bool _loading = true;
  bool _replying = false;

  /// AI 未配置 / 请求失败时的说明（一次性提示，不打断对话）
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final service = CompanionService.instance;
    final settings = app.companionSettings;
    final snapshot = await service.snapshot(app);
    final state = await service.loadState();
    // v1.33：记忆打开时先取回本机记忆（关掉就等于每次重新认识）
    final memory =
        settings.memoryEnabled ? await service.loadMemory() : CompanionMemory();
    // 用统计值做随机种子：同样的学习状态给同样的开场白，测试可复现
    final line = service.greet(
      snapshot,
      nickname: app.settings.nickname,
      rng: Random(snapshot.streakDays * 31 +
          snapshot.todayAnswered * 7 +
          snapshot.dueReviews),
    );
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _state = state;
      _mood = line.mood;
      _loading = false;
      _memory = memory;
      _settings = settings;
      _messages.clear();
      if (settings.memoryEnabled && memory.turns.isNotEmpty) {
        // 回填历史：用户一进来看到的是「上次聊到哪」，不是又一句开场白
        for (final turn in memory.turns) {
          _messages.add(turn.fromUser
              ? _ChatMessage.user(turn.text)
              : _ChatMessage.bot(turn.text));
        }
      } else {
        _messages.add(_ChatMessage.bot(line.text));
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _replying) return;
    _input.clear();

    final app = context.read<AppState>();
    final service = CompanionService.instance;
    final botMessage = _ChatMessage.bot('');
    setState(() {
      _messages
        ..add(_ChatMessage.user(text))
        ..add(botMessage);
      _replying = true;
    });
    _scrollToEnd();

    // 好感度：每天第一次见面 +3，其后每次 +1（只影响头像旁的数值）
    final state = await service.recordTalk();
    if (!mounted) return;
    setState(() => _state = state);

    final settings = app.companionSettings;
    // v1.33 知识库接地：先检索再说话；检索失败/没有库都返回空串，不打断对话
    final kbBlock = await service.knowledgeBlock(text, settings: settings);
    if (!mounted) return;
    final kbUsed = kbBlock.isNotEmpty;

    // 接口：独立配置优先，否则跟随「设置 → AI 接口」
    final ai = settings.hasOwnApi
        ? AIService(settings.resolve(app.settings))
        : app.aiService;
    final configured =
        settings.hasOwnApi || (app.settings.isConfigured && ai != null);
    var reply = service.fallbackReply(
      text,
      _snapshot,
      nickname: app.settings.nickname,
    );

    if (configured) {
      try {
        var acc = '';
        await for (final chunk in ai!.streamCompanionReply(
          systemPrompt: service.systemPrompt(settings: settings),
          userPrompt: service.buildPrompt(
            snapshot: _snapshot,
            userText: text,
            nickname: app.settings.nickname,
            settings: settings,
            memory: settings.memoryEnabled ? _memory : null,
            kbBlock: kbBlock,
          ),
        )) {
          acc = chunk;
          if (!mounted) return;
          setState(() => botMessage.text = acc);
        }
        if (acc.trim().isEmpty || AIService.isAiError(acc)) {
          if (mounted) {
            setState(() => _notice = 'AI 这次没有给出内容，先用固定文案陪你');
          }
        } else {
          reply = acc.trim();
        }
      } catch (_) {
        if (mounted) setState(() => _notice = 'AI 暂时连不上，先用固定文案陪你');
      } finally {
        // 独立配置的实例是一次性的（自带 http client），用完就放
        if (settings.hasOwnApi) ai?.dispose();
      }
    } else if (mounted) {
      setState(() =>
          _notice = '未配置 AI 接口，当前是固定文案模式（设置里填好 Key 会自动切换）');
    }
    if (!mounted) return;
    setState(() {
      botMessage.text = reply;
      botMessage.fromKb = kbUsed;
      _replying = false;
      _mood = _moodFor(text);
    });
    _scrollToEnd();

    // v1.33 记忆：只记「用户这句话 + 最终回复」，流式残片不落库
    if (settings.memoryEnabled) {
      try {
        await service.remember(
          _memory,
          fromUser: true,
          text: text,
          snapshot: _snapshot,
          nickname: app.settings.nickname,
        );
        await service.remember(
          _memory,
          fromUser: false,
          text: reply,
          snapshot: _snapshot,
          nickname: app.settings.nickname,
        );
        if (mounted) setState(() {});
      } catch (_) {
        // 记忆写失败不影响这一轮对话
      }
    }
  }

  /// 情绪跟随「说了什么」：错题/累→担心，今日达标→骄傲，被夸→开心，
  /// 其余保持打气。
  CompanionMood _moodFor(String userText) {
    if (userText.contains('累') ||
        userText.contains('困') ||
        userText.contains('错') ||
        userText.contains('难')) {
      return CompanionMood.worried;
    }
    if (_snapshot.reachedGoal) return CompanionMood.proud;
    if (userText.contains('夸')) return CompanionMood.happy;
    return CompanionMood.cheer;
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: NatsumeMotion.fast,
      curve: Curves.easeOut,
    );
  }


  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final app = context.watch<AppState>();
    final nickname = app.settings.nickname;
    final settings = app.companionSettings;
    final botName = settings.displayName;
    final service = CompanionService.instance;
    // v1.35：人设与记忆可同步（Key / 好感度不同步），标签跟着开关走
    final companionSyncOn =
        app.isPluginSyncEnabled(PluginSyncScope.companionPluginId);

    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: Text('$botName助教'),
        actions: [
          NatsumeIconButton(
            icon: Icons.tune_rounded,
            tooltip: '助教设置',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const CompanionSettingsScreen(),
              ));
              // 设置里可能改了名字 / 记忆开关 / 知识库，回来重载一次
              if (!mounted) return;
              setState(() => _loading = true);
              await _load();
            },
          ),
          NatsumeIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新统计',
            onPressed: _loading
                ? null
                : () async {
                    setState(() => _loading = true);
                    await _load();
                  },
          ),
          const SizedBox(width: NatsumeSpace.xxs),
        ],
      ),
      body: ResponsivePage(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(NatsumeSpace.md),
                children: [
                  // ── 角色卡：头像 + 名字 + 同步边界 + 好感度 ──
                  NatsumeSurface(
                    accentEdge: true,
                    padding: const EdgeInsets.all(NatsumeSpace.sm),
                    child: Row(
                      children: [
                        CompanionAvatarView(
                            settings: _settings, mood: _mood, size: 64),
                        const SizedBox(width: NatsumeSpace.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  // 名字过长时省略，别把「无法同步」标签挤出屏幕
                                  Flexible(
                                    child: Text(
                                      botName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: NatsumeType.h2Style
                                          .copyWith(color: ac.textPrimary),
                                    ),
                                  ),
                                  const SizedBox(width: NatsumeSpace.xs),
                                  // 同步边界：v1.35 起人设/记忆可同步，Key 与好感度仍本机
                                  NatsumeTag(
                                    companionSyncOn ? '人设可同步' : '仅本机',
                                    tone: companionSyncOn
                                        ? NatsumeTagTone.success
                                        : NatsumeTagTone.warning,
                                  ),
                                ],
                              ),
                              const SizedBox(height: NatsumeSpace.xxs),
                              Text(
                                '${_mood.label} · 好感度 ${_state.affection}'
                                '${nickname.isEmpty ? '' : ' · 陪你的是 $nickname'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NatsumeType.captionStyle
                                    .copyWith(color: ac.textSecondary),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                CompanionService.syncNotice,
                                style: NatsumeType.microStyle
                                    .copyWith(color: ac.textTertiary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: NatsumeSpace.sm),
                  // ── 真实统计（bot 说话的依据）──
                  Wrap(
                    spacing: NatsumeSpace.xxs,
                    runSpacing: NatsumeSpace.xxs,
                    children: [
                      NatsumeTag('连续打卡 ${_snapshot.streakDays} 天'),
                      NatsumeTag('今日 ${_snapshot.todayAnswered}/'
                          '${CompanionService.dailyGoal}'),
                      NatsumeTag('本周 ${_snapshot.weekAccuracyText}'),
                      NatsumeTag(
                        '待复习 ${_snapshot.dueReviews}',
                        tone: _snapshot.dueReviews > 0
                            ? NatsumeTagTone.warning
                            : NatsumeTagTone.neutral,
                      ),
                      // v1.33：记忆与接口来源都摆在明面上，用户不用猜
                      if (settings.memoryEnabled && _memory.length > 0)
                        NatsumeTag('记忆 ${_memory.length} 条'),
                      if (settings.hasOwnApi)
                        const NatsumeTag('独立接口',
                            tone: NatsumeTagTone.accent),
                      if (settings.kbEnabled)
                        const NatsumeTag('可查知识库',
                            tone: NatsumeTagTone.success),
                    ],
                  ),
                  if (_notice != null) ...[
                    const SizedBox(height: NatsumeSpace.xs),
                    Text(_notice!,
                        style: NatsumeType.microStyle
                            .copyWith(color: ac.textTertiary)),
                  ],
                  const SizedBox(height: NatsumeSpace.md),
                  // ── 对话气泡 ──
                  for (final m in _messages) ...[
                    _Bubble(message: m, settings: settings),
                    const SizedBox(height: NatsumeSpace.xs),
                  ],
                  if (_replying)
                    Padding(
                      padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
                      child: Text('$botName正在想…',
                          style: NatsumeType.microStyle
                              .copyWith(color: ac.textTertiary)),
                    ),
                  // ── 快捷问句：降低「不知道聊什么」的门槛 ──
                  Wrap(
                    spacing: NatsumeSpace.xxs,
                    runSpacing: NatsumeSpace.xxs,
                    children: [
                      for (final q in service.quickPrompts(_snapshot))
                        NatsumeChip(
                          label: q,
                          selected: false,
                          dense: true,
                          onTap: _replying ? null : () => _send(q),
                        ),
                    ],
                  ),
                  const SizedBox(height: NatsumeSpace.sm),
                  // ── 输入 ──
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: '跟$botName说点什么…',
                          ),
                        ),
                      ),
                      const SizedBox(width: NatsumeSpace.xs),
                      NatsumeIconButton(
                        icon: Icons.send_rounded,
                        tooltip: '发送',
                        onPressed: _replying ? null : () => _send(),
                      ),
                    ],
                  ),
                  const SizedBox(height: NatsumeSpace.sm),
                  Text(
                    '$botName只复述本机的真实统计；专业知识以教材与知识库为准，'
                    '不提供诊断与用药建议。',
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textTertiary, height: 1.6),
                  ),
                ],
              ),
      ),
    );
  }
}


/// 一条对话消息（bot 文本可流式更新，故 [text] 可变）
class _ChatMessage {
  _ChatMessage.bot(this.text) : fromUser = false;
  _ChatMessage.user(this.text) : fromUser = true;

  final bool fromUser;
  String text;

  /// 这条回复用到了知识库资料（v1.33：页面上标出来，用户才知道「凭据」）
  bool fromKb = false;
}

/// 对话气泡：bot 左对齐带小头像，用户右对齐带强调底。
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.settings});

  final _ChatMessage message;

  /// 气泡头像要跟「助教形象」设置一致（v1.35）
  final CompanionSettings settings;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final isUser = message.fromUser;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
      decoration: BoxDecoration(
        // 气泡不是卡片：bot 用面板色，用户用强调色的极淡底，靠明度区分
        color: isUser ? Color.lerp(ac.surface, ac.accent, 0.16) : ac.surfaceAlt,
        borderRadius: NatsumeRadius.cardBorder,
        border: Border.all(color: ac.border, width: NatsumeLine.width),
      ),
      child: Text(
        message.text,
        style: NatsumeType.bodyStyle.copyWith(
          color: isUser ? ac.textPrimary : ac.textSecondary,
          height: 1.6,
        ),
      ),
    );

    return Row(
      mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isUser) ...[
          CompanionAvatarView(settings: settings, size: 28),
          const SizedBox(width: NatsumeSpace.xs),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              bubble,
              if (!isUser && message.fromKb) ...[
                const SizedBox(height: 2),
                const NatsumeTag('依据知识库', tone: NatsumeTagTone.success),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

