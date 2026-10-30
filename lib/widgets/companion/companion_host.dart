import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/companion.dart';
import '../../models/companion_memory.dart';
import '../../models/companion_settings.dart';
import '../../screens/companion_screen.dart';
import '../../screens/companion_settings_screen.dart';
import '../../services/ai_service.dart';
import '../../services/app_state.dart';
import '../../services/companion/companion_service.dart';
import '../../services/theme_service.dart';
import '../../utils/design_tokens.dart';
import 'companion_avatar.dart';

/// 应用内悬浮「小鲸助教」（v1.33）。
///
/// 用户明确要的是**应用内浮层**，不是 Electron 式系统级桌面宠物：
/// 没有独立窗口、不置顶到桌面、不监听全局键盘——只在本 App 的
/// `MaterialApp.builder` 里画一层可拖动的头像 + 气泡，随 App 一起走。
///
/// 三条自我约束与 v1.32 一脉相承：
/// 1. **不打断输入**：浮层只在 `Stack` 上层放一个小头像，气泡 9 秒自动收，
///    做题（`currentSession != null`）时整体隐藏；
/// 2. **能关、能挪、能请走**：设置里可关、长按可「今天先别出现」，位置落
///    设置（归一化坐标），换分辨率不会跑出屏幕；
/// 3. **数字仍是真的**：气泡台词来自 `CompanionService.greet`，输入是
///    `CompanionService.snapshot` 的真实统计，不是随机彩虹屁。
///
/// ## v1.34 交互重做（用户原话「点一下 = 戳它一下，别直接跳大界面」）
///
/// - **单击 = 戳一下**：AI 就地在这个浮层里回一句（有聊天面板时回在面板里），
///   不再 `push` 全屏对话页——误触不会把人从正在看的页面带走；
/// - **右键（桌面）/ 长按（移动端）= 菜单**：「聊天」悬浮一个气泡输入框，
///   「设置」进助教设置（AI 接口 / 人格 / 知识库都在这页），另有
///   「今天先别出现」保留 v1.33 的「能请走」；
/// - **回退栈防重**：旧实现每次都 `nav.push`，连点会叠出好几层同样的页面、
///   返回要点很多次。现在同一种页面只允许一个实例（在途 + 在栈都算），
///   面板本身也是「开 / 收」而不是压栈。
class CompanionHost extends StatefulWidget {
  const CompanionHost({
    super.key,
    required this.child,
    this.navigatorKey,
    this.rng,
  });

  /// 通常是 `MaterialApp.builder` 传进来的 Navigator
  final Widget child;

  /// `builder` 的 context 在 Navigator **之上**，拿不到 `Navigator.of`，
  /// 所以点开对话页必须靠这把 key
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 台词随机源（测试注入固定种子，线上按时间取）
  final Random? rng;

  @override
  State<CompanionHost> createState() => _CompanionHostState();
}

class _CompanionHostState extends State<CompanionHost> {
  static const double _avatarSize = 56;
  static const double _edge = 10;

  /// 迷你聊天面板的默认宽度 / 最大高度（v1.34）
  static const double _panelWidth = 288;
  static const double _panelMaxHeight = 300;

  /// 气泡停留时长：够看完一句话，又不至于压在内容上不走
  static const Duration _bubbleHold = Duration(seconds: 9);

  final CompanionService _service = CompanionService.instance;

  CompanionSnapshot _snapshot = CompanionSnapshot.empty;
  CompanionLine? _bubble;
  Timer? _nudgeTimer;
  Timer? _hideTimer;

  /// 当前定时器配置的分钟数（null = 还没配过）
  int? _timerMinutes;

  /// 头像绝对坐标（px）；null = 用设置里的位置或默认右下角
  Offset? _pos;

  /// 右键 / 长按菜单是否展开
  bool _menuOpen = false;

  /// 迷你聊天气泡（输入框）是否展开。**不压栈**，纯状态开关
  bool _chatOpen = false;

  /// 迷你聊天面板的 state 句柄：戳一下时要把回话塞进正在开着的面板
  final GlobalKey<_MiniChatPanelState> _chatKey = GlobalKey<_MiniChatPanelState>();

  /// 已经在栈上 / 正在 push 的页面类型（`runtimeType.toString()`）。
  /// 用途见 [_openPage]：同一页只允许一个实例，避免连点叠层。
  final Set<String> _stackedPages = <String>{};

  @override
  void initState() {
    super.initState();
    // 首帧后再取统计：initState 里 context.read 还没准备好
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSnapshot());
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshSnapshot() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final snapshot = await _service.snapshot(app);
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
  }

  /// 取一句当前场景台词（真实统计 + 可注入随机源）
  Future<CompanionLine> _nextLine(AppState app) async {
    final snapshot = await _service.snapshot(app);
    if (mounted) setState(() => _snapshot = snapshot);
    return _service.greet(
      snapshot,
      nickname: app.settings.nickname,
      rng: widget.rng ?? Random(DateTime.now().millisecondsSinceEpoch),
    );
  }

  /// 定时冒泡（按设置里的分钟数）
  Future<void> _nudge() async {
    if (!mounted) return;
    final line = await _nextLine(context.read<AppState>());
    if (!mounted) return;
    setState(() {
      _bubble = line;
      _menuOpen = false;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(_bubbleHold, () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  /// **点一下 = 戳一下**：AI 在当前窗口回一句，**不进二级页面**。
  ///
  /// 聊天面板开着时这句直接落进面板（保证「回话在同一个窗口里」）；
  /// 面板没开就冒一个 9 秒自动收的气泡。
  Future<void> _poke() async {
    if (!mounted) return;
    final line = await _nextLine(context.read<AppState>());
    if (!mounted) return;
    final panel = _chatKey.currentState;
    if (panel != null) {
      panel.appendPoke(line);
      return;
    }
    setState(() {
      _bubble = line;
      _menuOpen = false;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(_bubbleHold, () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  /// 按当前设置对齐定时器（幂等：分钟数没变就什么都不做）
  void _syncTimer(int minutes) {
    if (_timerMinutes == minutes) return;
    _timerMinutes = minutes;
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    if (minutes <= 0) return;
    _nudgeTimer = Timer.periodic(Duration(minutes: minutes), (_) => _nudge());
  }

  /// 打开二级页（助教设置 / 全屏对话）：**同一种页面只允许一个实例**。
  ///
  /// 旧实现直接 `nav.push`，连点几下就叠出好几层同样的页面（返回要点好几
  /// 下，看起来像「页面重叠」）。这里用「同型页面在栈 / 在途」标记挡住重复
  /// 的 push：第一次点先占位，等这条路由被 pop（`push` 的 Future 完成）才
  /// 释放；`finally` 保证异常路径也会解锁。
  Future<void> _openPage(Widget page) async {
    if (_menuOpen || _chatOpen) {
      setState(() {
        _menuOpen = false;
        _chatOpen = false;
      });
    }
    final nav = widget.navigatorKey?.currentState;
    if (nav == null) return;
    final tag = page.runtimeType.toString();
    if (!_stackedPages.add(tag)) return;
    try {
      await nav.push(MaterialPageRoute<void>(builder: (_) => page));
    } finally {
      _stackedPages.remove(tag);
    }
  }

  /// 迷你聊天气泡：开 / 收（**不推页面**，所以连点也不会叠）
  void _toggleChat() {
    setState(() {
      _chatOpen = !_chatOpen;
      _menuOpen = false;
      if (_chatOpen) _bubble = null;
    });
    _hideTimer?.cancel();
  }

  /// 「今天先别出现」：只记日期，不改用户的悬浮开关
  Future<void> _hideForToday(AppState app) async {
    setState(() {
      _bubble = null;
      _menuOpen = false;
    });
    await app.updateCompanionSettings(
      app.companionSettings
          .copyWith(hiddenDay: () => companionDayKey(DateTime.now())),
    );
  }

  /// 拖动结束后把位置按屏幕比例存回去（换窗口大小也还在原来的相对位置）
  Future<void> _persistPosition(Size size) async {
    final p = _pos;
    if (p == null || size.width <= 0 || size.height <= 0) return;
    final app = context.read<AppState>();
    await app.updateCompanionSettings(app.companionSettings.copyWith(
      overlayX: () => (p.dx / size.width).clamp(0.0, 1.0).toDouble(),
      overlayY: () => (p.dy / size.height).clamp(0.0, 1.0).toDouble(),
    ));
  }

  Offset _clampPos(Offset p, Size size) {
    final maxX = max(_edge, size.width - _avatarSize - _edge);
    final maxY = max(_edge, size.height - _avatarSize - _edge);
    return Offset(
      p.dx.clamp(_edge, maxX).toDouble(),
      p.dy.clamp(_edge, maxY).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final settings = app.companionSettings;
    final today = companionDayKey(DateTime.now());
    // 做题时不冒头：陪伴是「别打断」，不是「无处不在」
    final visible = app.companionPluginEnabled &&
        settings.overlayEnabled &&
        !settings.hiddenOn(today) &&
        app.currentSession == null;
    _syncTimer(visible ? settings.bubbleMinutes : 0);
    if (!visible) return widget.child;

    final ac = AppThemeColors.of(context);
    final size = MediaQuery.sizeOf(context);
    final stored = (settings.overlayX != null && settings.overlayY != null)
        ? Offset(settings.overlayX! * size.width, settings.overlayY! * size.height)
        : null;
    // 默认位置：右下角、让开底部导航栏
    final fallback = Offset(
      size.width - _avatarSize - NatsumeSpace.md,
      size.height - _avatarSize - 104,
    );
    _pos ??= _clampPos(stored ?? fallback, size);
    final pos = _clampPos(_pos!, size);
    if (pos != _pos) _pos = pos;

    // 上方有空间就往上冒，否则落在头像下方
    final above = pos.dy > 160;
    final cardLeft = (pos.dx + _avatarSize - 220)
        .clamp(NatsumeSpace.xs, max(NatsumeSpace.xs, size.width - 228))
        .toDouble();
    final cardTop = above
        ? max(NatsumeSpace.xs, pos.dy - 132)
        : pos.dy + _avatarSize + NatsumeSpace.xs;

    // 迷你聊天面板几何：宽度随屏幕收窄、贴在头像旁边
    // （上方放得下就朝上弹，否则朝下，并把高度收进可视区）
    final panelWidth = min(_panelWidth, size.width - NatsumeSpace.md * 2);
    final panelLeft = (pos.dx + _avatarSize - panelWidth)
        .clamp(NatsumeSpace.xs,
            max(NatsumeSpace.xs, size.width - panelWidth - NatsumeSpace.xs))
        .toDouble();
    final panelAbove = pos.dy > _panelMaxHeight + NatsumeSpace.xl;
    final panelMaxHeight = panelAbove
        ? max(120.0, pos.dy - NatsumeSpace.xl)
        : max(120.0, size.height - pos.dy - _avatarSize - NatsumeSpace.md);
    final panel = _MiniChatPanel(
      key: _chatKey,
      appState: app,
      settings: settings,
      snapshot: _snapshot,
      botName: settings.displayName,
      maxHeight: panelMaxHeight,
      onClose: () => setState(() => _chatOpen = false),
      onExpand: () => _openPage(const CompanionScreen()),
      rng: widget.rng,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: pos.dx,
          top: pos.dy,
          child: _avatar(app, settings, ac, size),
        ),
        if (_bubble != null)
          Positioned(
            left: cardLeft,
            top: cardTop,
            width: 220,
            child: _BubbleCard(
              text: _bubble!.text,
              mood: _bubble!.mood,
              botName: settings.displayName,
              // 气泡也不跳页：点它就开聊天面板（v1.34）
              onTap: _toggleChat,
            ),
          ),
        if (_menuOpen)
          Positioned(
            left: cardLeft,
            top: above
                ? max(NatsumeSpace.xs, pos.dy - 186)
                : pos.dy + _avatarSize + NatsumeSpace.xs,
            width: 220,
            child: _menuCard(app, settings, ac),
          ),
        if (_chatOpen)
          panelAbove
              ? Positioned(
                  left: panelLeft,
                  bottom: size.height - pos.dy + NatsumeSpace.xs,
                  width: panelWidth,
                  child: panel,
                )
              : Positioned(
                  left: panelLeft,
                  top: pos.dy + _avatarSize + NatsumeSpace.xs,
                  width: panelWidth,
                  child: panel,
                ),
      ],
    );
  }

  /// 菜单开 / 收（右键与长按共用）
  void _toggleMenu() => setState(() {
        _menuOpen = !_menuOpen;
        if (_menuOpen) _chatOpen = false;
      });

  Widget _avatar(
    AppState app,
    CompanionSettings settings,
    AppThemeColors ac,
    Size size,
  ) {
    return GestureDetector(
      key: const ValueKey('companionAvatar'),
      behavior: HitTestBehavior.opaque,
      // 单击 = 戳一下：AI 就地回话，**不进二级页面**（v1.34）
      onTap: _poke,
      // 右键（桌面）/ 长按（移动端）= 聊天 / 设置 菜单
      onSecondaryTap: _toggleMenu,
      onLongPress: _toggleMenu,
      onPanStart: (_) {
        if (_menuOpen) setState(() => _menuOpen = false);
      },
      onPanUpdate: (d) {
        setState(() {
          _pos = _clampPos((_pos ?? Offset.zero) + d.delta, size);
        });
      },
      onPanEnd: (_) => _persistPosition(size),
      child: Semantics(
        label: '${settings.displayName}助教（可拖动，右键或长按有菜单）',
        button: true,
        child: Container(
          width: _avatarSize,
          height: _avatarSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ac.surface,
            border: Border.all(color: ac.surface, width: 2),
            boxShadow: NatsumeShadow.level2,
          ),
          child: ClipOval(
            child: Image.asset(
              CompanionService.avatarAsset,
              fit: BoxFit.cover,
              // 图标缺失也不能让浮层崩：退回 v1.32 的自绘头像
              errorBuilder: (_, __, ___) => CompanionAvatar(
                mood: _bubble?.mood ?? CompanionMood.idle,
                size: _avatarSize,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuCard(
    AppState app,
    CompanionSettings settings,
    AppThemeColors ac,
  ) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: ac.surface,
          borderRadius: NatsumeRadius.cardBorder,
          border: Border.all(color: ac.border, width: NatsumeLine.width),
          boxShadow: NatsumeShadow.level2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 菜单顶部放一行真实统计：用户长按就知道「小鲸看到的是什么数」，
            // 也让 `_snapshot` 不只是气泡用的临时变量
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NatsumeSpace.sm, NatsumeSpace.xs, NatsumeSpace.sm, 2),
              child: Text(
                '今天 ${_snapshot.todayAnswered}/${CompanionSnapshot.dailyGoal} 题'
                ' · 连续 ${_snapshot.streakDays} 天',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
              ),
            ),
            Divider(height: 1, color: ac.border),
            _MenuItem(
              key: const ValueKey('companionChatMenu'),
              icon: Icons.chat_bubble_outline_rounded,
              label: _chatOpen ? '收起聊天' : '聊天',
              onTap: _toggleChat,
            ),
            _MenuItem(
              key: const ValueKey('companionSettingsMenu'),
              icon: Icons.tune_rounded,
              label: '设置',
              onTap: () => _openPage(const CompanionSettingsScreen()),
            ),
            _MenuItem(
              key: const ValueKey('companionHideMenu'),
              icon: Icons.visibility_off_outlined,
              label: '今天先别出现',
              onTap: () => _hideForToday(app),
            ),
          ],
        ),
      ),
    );
  }
}

/// 气泡卡片：白底 + 一行角色名 + 正文；点一下开聊天面板（不跳页，v1.34）
class _BubbleCard extends StatelessWidget {
  const _BubbleCard({
    required this.text,
    required this.mood,
    required this.botName,
    required this.onTap,
  });

  final String text;
  final CompanionMood mood;
  final String botName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Material(
      key: const ValueKey('companionBubble'),
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: NatsumeRadius.cardBorder,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
          decoration: BoxDecoration(
            color: ac.surface,
            borderRadius: NatsumeRadius.cardBorder,
            border: Border.all(color: ac.border, width: NatsumeLine.width),
            boxShadow: NatsumeShadow.level2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      botName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NatsumeType.microStyle.copyWith(
                        color: ac.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: NatsumeSpace.xxs),
                  Text(
                    mood.label,
                    style:
                        NatsumeType.microStyle.copyWith(color: ac.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: NatsumeType.captionStyle.copyWith(
                  color: ac.textPrimary,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 迷你聊天面板（v1.34）：悬浮在头像旁边的「气泡输入框」。
///
/// 用户原话：「选聊天则会悬浮一个气泡输入框，禁止点击直接进入大界面」。
/// 所以聊天不跳页，而是就地弹一小块面板：上面几行对话、下面一个输入框，
/// 回车即发；想用完整页面时点右上角「⤢」——那是明确动作，不是误触。
///
/// 与完整页（`CompanionScreen`）共用同一套服务：真统计、知识库接地、
/// 对话记忆、好感度都照旧，只是换了块更小的皮。
class _MiniChatPanel extends StatefulWidget {
  const _MiniChatPanel({
    super.key,
    required this.appState,
    required this.settings,
    required this.snapshot,
    required this.botName,
    required this.maxHeight,
    required this.onClose,
    required this.onExpand,
    this.rng,
  });

  final AppState appState;
  final CompanionSettings settings;
  final CompanionSnapshot snapshot;
  final String botName;
  final double maxHeight;
  final VoidCallback onClose;
  final VoidCallback onExpand;
  final Random? rng;

  @override
  State<_MiniChatPanel> createState() => _MiniChatPanelState();
}

class _MiniChatPanelState extends State<_MiniChatPanel> {
  /// 面板里的对话只留最近几条：面板是「随手问一句」，不是聊天记录页
  static const int _maxMessages = 8;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_MiniMessage> _messages = [];

  CompanionMemory _memory = CompanionMemory();
  late CompanionSnapshot _snapshot = widget.snapshot;
  CompanionMood _mood = CompanionMood.idle;
  bool _replying = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadMemory();
  }

  @override
  void didUpdateWidget(covariant _MiniChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主刷新统计后跟着更新：数字必须和使用它的那句话同源
    _snapshot = widget.snapshot;
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 打开面板先接上上次聊到哪（记忆关掉就等于每次重新认识）
  Future<void> _loadMemory() async {
    final service = CompanionService.instance;
    CompanionMemory memory = CompanionMemory();
    if (widget.settings.memoryEnabled) {
      try {
        memory = await service.loadMemory();
      } catch (_) {
        // 记忆读失败不影响聊天
      }
    }
    if (!mounted) return;
    setState(() {
      _memory = memory;
      _loaded = true;
      final turns = memory.turns;
      final from = turns.length > 4 ? turns.length - 4 : 0;
      for (final turn in turns.sublist(from)) {
        _messages.add(turn.fromUser
            ? _MiniMessage.user(turn.text)
            : _MiniMessage.bot(turn.text));
      }
    });
    _scrollToEnd();
  }

  /// 「戳一下」的回话：直接作为一句 bot 消息落进面板
  void appendPoke(CompanionLine line) {
    if (!mounted) return;
    setState(() {
      _mood = line.mood;
      _messages.add(_MiniMessage.bot(line.text));
    });
    _trim();
    _scrollToEnd();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _replying) return;
    _input.clear();

    final app = widget.appState;
    final service = CompanionService.instance;
    final botMessage = _MiniMessage.bot('');
    setState(() {
      _messages
        ..add(_MiniMessage.user(text))
        ..add(botMessage);
      _replying = true;
    });
    _trim();
    _scrollToEnd();

    // 好感度与完整页同口径：当天首次 +3，其后 +1
    try {
      await service.recordTalk();
    } catch (_) {
      // 好感度写失败不该拦着说话
    }
    if (!mounted) return;

    final settings = widget.settings;
    final kbBlock = await service.knowledgeBlock(text, settings: settings);
    if (!mounted) return;
    final kbUsed = kbBlock.isNotEmpty;

    final ai = settings.hasOwnApi
        ? AIService(settings.resolve(app.settings))
        : app.aiService;
    final configured =
        settings.hasOwnApi || (app.settings.isConfigured && ai != null);
    var reply = service.fallbackReply(
      text,
      _snapshot,
      nickname: app.settings.nickname,
      rng: widget.rng,
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
          _toast('AI 这次没有给出内容，先用固定文案陪你');
        } else {
          reply = acc.trim();
        }
      } catch (_) {
        _toast('AI 暂时连不上，先用固定文案陪你');
      } finally {
        // 独立配置的实例是一次性的（自带 http client），用完就放
        if (settings.hasOwnApi) ai?.dispose();
      }
    } else {
      _toast('未配置 AI 接口，当前是固定文案模式');
    }
    if (!mounted) return;
    setState(() {
      botMessage.text = reply;
      botMessage.fromKb = kbUsed;
      _mood = _moodFor(text);
      _replying = false;
    });
    _scrollToEnd();

    // 记忆只记「用户这句 + 最终回复」，流式残片不落库
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
      } catch (_) {
        // 记忆写失败不影响这一轮
      }
    }
  }
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

  void _trim() {
    if (_messages.length <= _maxMessages) return;
    _messages.removeRange(0, _messages.length - _maxMessages);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 2),
    ));
  }
  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Material(
      key: const ValueKey('companionChatPanel'),
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        padding: const EdgeInsets.all(NatsumeSpace.xs),
        decoration: BoxDecoration(
          color: ac.surface,
          borderRadius: NatsumeRadius.cardBorder,
          border: Border.all(color: ac.border, width: NatsumeLine.width),
          boxShadow: NatsumeShadow.level3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CompanionAvatar(mood: _mood, size: 20),
                const SizedBox(width: NatsumeSpace.xxs),
                Expanded(
                  child: Text(
                    widget.botName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.microStyle.copyWith(
                      color: ac.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _PanelIconButton(
                  icon: Icons.open_in_full_rounded,
                  label: '在完整对话页打开',
                  onTap: widget.onExpand,
                ),
                _PanelIconButton(
                  icon: Icons.close_rounded,
                  label: '收起',
                  onTap: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: NatsumeSpace.xxs),
            Flexible(
              child: !_loaded
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: NatsumeSpace.xs),
                      child: Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : _messages.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: NatsumeSpace.xs),
                          child: Text(
                            '点我一下，或者直接说点什么～',
                            style: NatsumeType.captionStyle
                                .copyWith(color: ac.textTertiary),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _messages.length,
                          itemBuilder: (_, i) =>
                              _MiniBubble(message: _messages[i]),
                        ),
            ),
            const SizedBox(height: NatsumeSpace.xxs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '跟${widget.botName}说点什么…',
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: NatsumeSpace.xs, vertical: 6),
                    ),
                  ),
                ),
                const SizedBox(width: NatsumeSpace.xxs),
                _PanelIconButton(
                  icon: Icons.arrow_upward_rounded,
                  label: '发送',
                  size: 18,
                  filled: true,
                  onTap: _replying ? null : _send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 菜单的一行（右键 / 长按唤出的那张小卡）
class _MenuItem extends StatelessWidget {
  const _MenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
        child: Row(
          children: [
            Icon(icon, size: 16, color: ac.textSecondary),
            const SizedBox(width: NatsumeSpace.xs),
            Expanded(
              child: Text(
                label,
                style: NatsumeType.captionStyle.copyWith(color: ac.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面板按钮（比 IconButton 更省空间）。
///
/// **不能用 Tooltip**：`CompanionHost` 挂在 `MaterialApp.builder` 上，位于
/// Navigator 之上，而 Tooltip 需要一个 Overlay 祖先（Overlay 在 Navigator 里，
/// 是它的**后代**）——用了会在 debug 下直接抛 "No Overlay widget found"。
/// 所以这里只用 Semantics 提供无障碍标签。
class _PanelIconButton extends StatelessWidget {
  const _PanelIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 14,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final ink = filled ? ac.onAccent : ac.textTertiary;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: filled ? ac.accent : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(filled ? 6 : 3),
            child: Icon(icon, size: size, color: ink),
          ),
        ),
      ),
    );
  }
}

/// 面板里的一条消息（bot 文本可流式更新，故 [text] 可变）
class _MiniMessage {
  _MiniMessage.bot(this.text) : fromUser = false;
  _MiniMessage.user(this.text) : fromUser = true;

  final bool fromUser;
  String text;

  /// 这条回复用到了知识库资料（面板小，只标一个小字）
  bool fromKb = false;
}

/// 面板里的气泡：用户右、bot 左，靠明度区分
class _MiniBubble extends StatelessWidget {
  const _MiniBubble({required this.message});

  final _MiniMessage message;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final isUser = message.fromUser;
    final text = message.text.trim();
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.xs, vertical: 4),
        constraints: const BoxConstraints(maxWidth: 216),
        decoration: BoxDecoration(
          color:
              isUser ? Color.lerp(ac.surface, ac.accent, 0.16) : ac.surfaceAlt,
          borderRadius: BorderRadius.circular(NatsumeRadius.chip),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text.isEmpty ? '…' : text,
              style: NatsumeType.captionStyle.copyWith(
                color: isUser ? ac.textPrimary : ac.textSecondary,
                height: 1.5,
              ),
            ),
            if (!isUser && message.fromKb)
              Text(
                '依据知识库',
                style: NatsumeType.microStyle.copyWith(color: ac.success),
              ),
          ],
        ),
      ),
    );
  }
}
