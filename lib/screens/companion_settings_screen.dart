import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/companion.dart';
import '../models/companion_avatar.dart';
import '../models/companion_memory.dart';
import '../models/companion_settings.dart';
import '../models/knowledge_base.dart';
import '../services/ai_service.dart';
import '../services/app_state.dart';
import '../services/companion/companion_service.dart';
import '../services/knowledge_base/kb_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/companion/companion_avatar_view.dart';
import '../widgets/kit/natsume_kit.dart';

/// 「小鲸助教」设置页（v1.33）。
///
/// 一个页面收齐全部可配项：
/// - 头像 / 气泡：是否显示悬浮头像、多久冒一次泡、今天先别出现；
/// - 人格设定：角色名、四种语气、自定义人设；
/// - 模型接口：跟随软件 或 独立配置（地址 / 模型 / Key），可拉模型、可测连接；
/// - 知识库：开关 + 指定库（默认全部）；
/// - 记忆：开关 + 清空（只存本机，不参与同步）。
///
/// 保存策略分两种：开关/分段控件**即时生效**（用户点一下就看到结果），
/// 文本框走底部「保存设置」（避免每敲一个字就写一次库）。
class CompanionSettingsScreen extends StatefulWidget {
  const CompanionSettingsScreen({super.key});

  @override
  State<CompanionSettingsScreen> createState() =>
      _CompanionSettingsScreenState();
}

class _CompanionSettingsScreenState extends State<CompanionSettingsScreen> {
  late CompanionSettings _settings;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _personaCtrl;
  late final TextEditingController _endpointCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _keyCtrl;

  bool _obscureKey = true;
  bool _saving = false;
  bool _testing = false;
  bool _fetching = false;

  String? _testResult;
  bool _testOk = false;

  List<String> _modelOptions = const [];
  String? _modelsError;

  List<KnowledgeBase> _kbs = const [];
  int _memoryCount = 0;

  @override
  void initState() {
    super.initState();
    _settings = context.read<AppState>().companionSettings;
    _nameCtrl = TextEditingController(text: _settings.botName);
    _personaCtrl = TextEditingController(text: _settings.customPersona);
    _endpointCtrl = TextEditingController(text: _settings.endpoint);
    _modelCtrl = TextEditingController(text: _settings.model);
    _keyCtrl = TextEditingController(text: _settings.apiKey);
    _loadAux();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _personaCtrl.dispose();
    _endpointCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAux() async {
    try {
      final kbs = await KbService.instance.listKnowledgeBases();
      final memory = await CompanionService.instance.loadMemory();
      if (!mounted) return;
      setState(() {
        _kbs = kbs;
        _memoryCount = memory.length;
      });
    } catch (_) {
      // 知识库没建过 / 读取失败：页面照常可用，只是没有库可选
    }
  }

  /// 表单里的当前值（还没点保存也要能「测试连接」）
  CompanionSettings get _formValue => _settings.copyWith(
        botName: _nameCtrl.text.trim(),
        customPersona: _personaCtrl.text.trim(),
        endpoint: _endpointCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
      );

  /// 即时生效的改动（开关 / 分段控件）
  Future<void> _apply(CompanionSettings next) async {
    setState(() => _settings = next);
    await context.read<AppState>().updateCompanionSettings(next);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final next = _formValue;
    await context.read<AppState>().updateCompanionSettings(next);
    if (!mounted) return;
    setState(() {
      _settings = next;
      _saving = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('助教设置已保存')),
    );
  }

  Future<void> _fetchModels() async {
    if (_fetching) return;
    setState(() {
      _fetching = true;
      _modelOptions = const [];
      _modelsError = null;
    });
    final app = context.read<AppState>();
    final temp = _formValue;
    // 跟随软件模式就拿 App 的 Key 去拉模型，方便用户照着填
    final effective = temp.hasOwnApi ? temp.resolve(app.settings) : app.settings;
    final svc = AIService(effective);
    try {
      final (models, err) = await svc.fetchModels();
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _modelOptions = models;
        _modelsError = err;
        if (models.length == 1) _modelCtrl.text = models.first;
      });
    } finally {
      svc.dispose();
      if (mounted && _fetching) setState(() => _fetching = false);
    }
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    final app = context.read<AppState>();
    final temp = _formValue;
    final effective = temp.hasOwnApi ? temp.resolve(app.settings) : app.settings;
    if (!effective.isConfigured) {
      setState(() {
        _testOk = false;
        _testResult = '还没有可用的 API Key：先填独立配置，或去「设置 → AI 接口」填好';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final svc = AIService(effective);
    try {
      final (ok, msg) = await svc.testConnection();
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = ok;
        _testResult = msg;
      });
    } finally {
      svc.dispose();
      if (mounted && _testing) setState(() => _testing = false);
    }
  }

  Future<void> _clearMemory() async {
    await CompanionService.instance.clearMemory();
    if (!mounted) return;
    setState(() => _memoryCount = 0);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本机记忆已清空')),
    );
  }

  // ======================== 界面 ========================

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final today = companionDayKey(DateTime.now());

    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('助教设置'),
        actions: [
          NatsumeIconButton(
            icon: Icons.check_rounded,
            tooltip: '保存',
            onPressed: _saving ? null : _save,
          ),
          const SizedBox(width: NatsumeSpace.xs),
        ],
      ),
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            _avatarSection(ac),
            const SizedBox(height: NatsumeSpace.md),
            _overlaySection(ac, today),
            const SizedBox(height: NatsumeSpace.md),
            _personaSection(ac),
            const SizedBox(height: NatsumeSpace.md),
            _memorySection(ac),
            const SizedBox(height: NatsumeSpace.md),
            _apiSection(ac, context.watch<AppState>()),
            const SizedBox(height: NatsumeSpace.md),
            _kbSection(ac),
            const SizedBox(height: NatsumeSpace.md),
            NatsumeButton(
              label: _saving ? '保存中…' : '保存设置',
              icon: Icons.check_rounded,
              expand: true,
              onPressed: _saving ? null : _save,
            ),
            const SizedBox(height: NatsumeSpace.md),
            Text(
              '角色人设与对话记忆会随局域网同步（可在「设置 → 同步与提醒 → 插件内容同步」里关掉）；'
              'API Key、好感度与悬浮位置只留本机。',
              style: NatsumeType.microStyle
                  .copyWith(color: ac.textTertiary, height: 1.6),
            ),
            const SizedBox(height: NatsumeSpace.lg),
          ],
        ),
      ),
    );
  }

  Widget _section(
    AppThemeColors ac, {
    required String title,
    String hint = '',
    required List<Widget> children,
  }) {
    return NatsumeSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: NatsumeSpace.xxs),
            Text(hint,
                style: NatsumeType.captionStyle
                    .copyWith(color: ac.textSecondary, height: 1.5)),
          ],
          const SizedBox(height: NatsumeSpace.sm),
          ...children,
        ],
      ),
    );
  }

  /// 开关行：自己拼 Row 而不是 SwitchListTile——卡片有底色，
  /// SwitchListTile 会触发「水波纹可能不可见」的 debug 断言。
  Widget _switchRow(
    AppThemeColors ac, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    IconData? icon,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: value ? ac.accent : ac.textTertiary),
          const SizedBox(width: NatsumeSpace.xs),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: NatsumeType.bodyStyle.copyWith(
                    color: ac.textPrimary,
                    fontWeight: FontWeight.w500,
                  )),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: NatsumeType.microStyle
                      .copyWith(color: ac.textTertiary, height: 1.5)),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _label(AppThemeColors ac, String text) => Padding(
        padding: const EdgeInsets.only(bottom: NatsumeSpace.xxs),
        child: Text(text,
            style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
      );

  // ── 助教形象 ──
  Widget _avatarSection(AppThemeColors ac) {
    final current = _settings.avatarOption;
    return _section(
      ac,
      title: '助教形象',
      hint: '三张角色图是官方插件 natsume.companion 自带资产'
          '（assets/plugins/official/companion/avatars）；'
          '换形象只改外观，统计口径与提示词一字不动，选完立即生效。',
      children: [
        Wrap(
          spacing: NatsumeSpace.sm,
          runSpacing: NatsumeSpace.sm,
          children: [
            for (final option in CompanionAvatarOption.all)
              _avatarChoice(ac, option),
          ],
        ),
        const SizedBox(height: NatsumeSpace.xxs),
        Text(
          '当前：${current.label}${current.hint.isEmpty ? '' : ' · ${current.hint}'}',
          style:
              NatsumeType.microStyle.copyWith(color: ac.textTertiary, height: 1.5),
        ),
      ],
    );
  }

  Widget _avatarChoice(AppThemeColors ac, CompanionAvatarOption option) {
    final selected = _settings.avatar == option.id;
    return Semantics(
      label: '助教形象 ${option.label}${selected ? '（当前）' : ''}',
      selected: selected,
      button: true,
      child: InkWell(
        key: ValueKey('companionAvatarChoice-${option.id}'),
        borderRadius: BorderRadius.circular(NatsumeRadius.card),
        onTap: () => _apply(_settings.copyWith(avatar: option.id)),
        child: Container(
          width: 92,
          padding: const EdgeInsets.symmetric(
              horizontal: NatsumeSpace.xs, vertical: NatsumeSpace.xs),
          decoration: BoxDecoration(
            color: selected ? ac.accentSoft : ac.surfaceAlt,
            borderRadius: BorderRadius.circular(NatsumeRadius.card),
            border: Border.all(
              color: selected ? ac.accent : ac.border,
              width: selected ? 1.5 : NatsumeLine.width,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 预览用同一套渲染：默认项是自绘头像，角色项是官方插件资产
              CompanionAvatarView(
                settings: _settings.copyWith(avatar: option.id),
                size: 48,
              ),
              const SizedBox(height: NatsumeSpace.xxs),
              Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NatsumeType.microStyle.copyWith(
                  color: selected ? ac.accent : ac.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 悬浮头像 / 气泡 ──
  Widget _overlaySection(AppThemeColors ac, String today) {
    final hiddenToday = _settings.hiddenOn(today);
    return _section(
      ac,
      title: '悬浮小鲸',
      hint: '开启后小鲸会以应用内浮层待在任何页面；按住可拖动，长按弹出菜单'
          '（对话 / 设置 / 今天先别出现）。这不是系统级桌面宠物，不会盖到别的软件上。',
      children: [
        _switchRow(
          ac,
          title: _settings.overlayEnabled ? '悬浮头像已开启' : '悬浮头像已关闭',
          subtitle: '关闭后仍可从「我的 → 学习工具 → 小鲸助教」进入对话页',
          value: _settings.overlayEnabled,
          icon: Icons.bubble_chart_outlined,
          onChanged: (v) => _apply(_settings.copyWith(overlayEnabled: v)),
        ),
        const SizedBox(height: NatsumeSpace.sm),
        _label(ac, '气泡提醒频率'),
        NatsumeSegmentedControl<int>(
          dense: true,
          value: _settings.bubbleMinutes,
          segments: const [
            (0, '关闭'),
            (10, '10 分'),
            (20, '20 分'),
            (30, '30 分'),
          ],
          onChanged: (v) => _apply(_settings.copyWith(bubbleMinutes: v)),
        ),
        const SizedBox(height: NatsumeSpace.xxs),
        Text(
          _settings.bubbleMinutes == 0
              ? '气泡已关闭：小鲸不会主动说话，只在你点她时出现。'
              : '每 ${_settings.bubbleMinutes} 分钟最多冒一次泡，内容依据真实学习数据；'
                  '做题时会自动隐藏，不打断你。',
          style: NatsumeType.microStyle
              .copyWith(color: ac.textTertiary, height: 1.5),
        ),
        if (hiddenToday) ...[
          const SizedBox(height: NatsumeSpace.sm),
          Row(
            children: [
              const NatsumeTag('今天已被请走', tone: NatsumeTagTone.warning),
              const Spacer(),
              NatsumeButton(
                label: '让她回来',
                kind: NatsumeButtonKind.ghost,
                dense: true,
                onPressed: () =>
                    _apply(_settings.copyWith(hiddenDay: () => null)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── 人格设定 ──
  Widget _personaSection(AppThemeColors ac) {
    return _section(
      ac,
      title: '人格设定',
      hint: '只影响「怎么说」，不放开两条硬约束：数字必须来自本机真实统计、'
          '不给诊断与用药建议。',
      children: [
        _label(ac, '角色名'),
        TextField(
          controller: _nameCtrl,
          maxLength: CompanionSettings.maxNameChars,
          decoration: const InputDecoration(
            hintText: CompanionSettings.defaultBotName,
            counterText: '',
          ),
        ),
        const SizedBox(height: NatsumeSpace.sm),
        _label(ac, '语气'),
        NatsumeSegmentedControl<CompanionTone>(
          dense: true,
          value: _settings.tone,
          segments: [
            for (final t in CompanionTone.values) (t, t.label),
          ],
          onChanged: (v) => _apply(_settings.copyWith(tone: v)),
        ),
        const SizedBox(height: NatsumeSpace.xxs),
        Text(_settings.tone.hint,
            style: NatsumeType.microStyle
                .copyWith(color: ac.textTertiary, height: 1.5)),
        const SizedBox(height: NatsumeSpace.sm),
        _label(ac, '自定义人设（可留空）'),
        TextField(
          controller: _personaCtrl,
          minLines: 3,
          maxLines: 6,
          maxLength: CompanionSettings.maxPersonaChars,
          decoration: const InputDecoration(
            hintText: '例：你是我的学姐助教，说话简短，喜欢用「嗯」开头；'
                '我拖延的时候直接点出来，但别骂我。',
          ),
        ),
      ],
    );
  }

  // ── 记忆 ──
  Widget _memorySection(AppThemeColors ac) {
    return _section(
      ac,
      title: '记忆',
      hint: '小鲸会记住最近的对话（本机最多 ${CompanionMemory.maxTurns} 条）与你的'
          '真实学习状态摘要，下次打开能接上话。',
      children: [
        _switchRow(
          ac,
          title: _settings.memoryEnabled ? '记忆已开启' : '记忆已关闭',
          subtitle: '关闭后每次进入对话页都从开场白开始',
          value: _settings.memoryEnabled,
          icon: Icons.psychology_outlined,
          onChanged: (v) => _apply(_settings.copyWith(memoryEnabled: v)),
        ),
        const SizedBox(height: NatsumeSpace.sm),
        Row(
          children: [
            NatsumeTag('已记 $_memoryCount 条', tone: NatsumeTagTone.neutral),
            const SizedBox(width: NatsumeSpace.xs),
            const NatsumeTag('仅本机', tone: NatsumeTagTone.accent),
            const Spacer(),
            NatsumeButton(
              label: '清空记忆',
              kind: NatsumeButtonKind.ghost,
              dense: true,
              onPressed: _memoryCount == 0 ? null : _clearMemory,
            ),
          ],
        ),
      ],
    );
  }


  // ── AI 接口 ──
  Widget _apiSection(AppThemeColors ac, AppState app) {
    final custom = _settings.apiMode == CompanionApiMode.custom;
    final followReady = app.settings.isConfigured && app.aiService != null;
    return _section(
      ac,
      title: 'AI 接口',
      hint: '小鲸默认跟随软件里已填好的 AI 配置，不用再填一遍；'
          '也可以单独配一个更便宜的模型，免得聊天把解析额度用光。',
      children: [
        NatsumeSegmentedControl<CompanionApiMode>(
          dense: true,
          value: _settings.apiMode,
          segments: [for (final m in CompanionApiMode.values) (m, m.label)],
          onChanged: (v) => _apply(_settings.copyWith(apiMode: v)),
        ),
        const SizedBox(height: NatsumeSpace.sm),
        if (!custom) ...[
          Row(
            children: [
              NatsumeTag(
                followReady ? '跟随中' : '软件未配置 Key',
                tone: followReady
                    ? NatsumeTagTone.success
                    : NatsumeTagTone.warning,
              ),
              const SizedBox(width: NatsumeSpace.xs),
              Expanded(
                child: Text(
                  '${app.settings.providerKind.label} · ${app.settings.model}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xxs),
          Text(
            '要改这份配置，去「设置 → AI 接口」；那边的改动会立刻同步给小鲸。',
            style: NatsumeType.microStyle
                .copyWith(color: ac.textTertiary, height: 1.5),
          ),
        ] else ...[
          _label(ac, '提供方'),
          Wrap(
            spacing: NatsumeSpace.xs,
            runSpacing: NatsumeSpace.xs,
            children: [
              for (final k in AiProviderKind.values)
                NatsumeChip(
                  label: k.label,
                  selected: _settings.providerKind == k,
                  dense: true,
                  onTap: () => _apply(_settings.copyWith(providerKind: k)),
                ),
            ],
          ),
          const SizedBox(height: NatsumeSpace.sm),
          _label(ac, '接口地址（留空用默认）'),
          TextField(
            controller: _endpointCtrl,
            decoration: const InputDecoration(
              hintText: AppSettings.defaultApiEndpoint,
            ),
          ),
          const SizedBox(height: NatsumeSpace.sm),
          _label(ac, '模型（留空用默认）'),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              hintText: AppSettings.defaultModel,
            ),
          ),
          const SizedBox(height: NatsumeSpace.xs),
          Wrap(
            spacing: NatsumeSpace.xs,
            runSpacing: NatsumeSpace.xs,
            children: [
              NatsumeButton(
                label: _fetching ? '拉取中…' : '拉取可用模型',
                kind: NatsumeButtonKind.secondary,
                dense: true,
                icon: Icons.download_rounded,
                onPressed: _fetching ? null : _fetchModels,
              ),
              NatsumeButton(
                label: _testing ? '测试中…' : '测试连接',
                kind: NatsumeButtonKind.secondary,
                dense: true,
                icon: Icons.bolt_outlined,
                onPressed: _testing ? null : _testConnection,
              ),
            ],
          ),
          if (_modelsError != null) ...[
            const SizedBox(height: NatsumeSpace.xxs),
            Text(_modelsError!,
                style: NatsumeType.microStyle
                    .copyWith(color: ac.danger, height: 1.5)),
          ],
          if (_modelOptions.isNotEmpty) ...[
            const SizedBox(height: NatsumeSpace.xs),
            Wrap(
              spacing: NatsumeSpace.xxs,
              runSpacing: NatsumeSpace.xxs,
              children: [
                for (final m in _modelOptions)
                  NatsumeChip(
                    label: m,
                    selected: _modelCtrl.text.trim() == m,
                    dense: true,
                    onTap: () => setState(() => _modelCtrl.text = m),
                  ),
              ],
            ),
          ],
          const SizedBox(height: NatsumeSpace.sm),
          _label(ac, 'API Key（本机加密保存）'),
          TextField(
            controller: _keyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              hintText: 'sk-…',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          if (_testResult != null) ...[
            const SizedBox(height: NatsumeSpace.xs),
            Text(
              _testResult!,
              style: NatsumeType.microStyle.copyWith(
                color: _testOk ? ac.success : ac.danger,
                height: 1.5,
              ),
            ),
          ],
        ],
        const SizedBox(height: NatsumeSpace.sm),
        Text(
          '文本框改完记得点「保存设置」。独立配置只在陪伴对话里生效，'
          '不影响解析、追问与出题。',
          style: NatsumeType.microStyle
              .copyWith(color: ac.textTertiary, height: 1.5),
        ),
      ],
    );
  }

  // ── 知识库 ──
  Widget _kbSection(AppThemeColors ac) {
    return _section(
      ac,
      title: '知识库',
      hint: '开启后小鲸回答前会先检索你导入的资料，能引用就说明出处；'
          '资料没覆盖的部分会讲清楚「这是通用知识」。',
      children: [
        _switchRow(
          ac,
          title: _settings.kbEnabled ? '可以查资料' : '只用通用知识',
          subtitle: '关闭后回答不检索知识库，回复更快，但可能给不出资料依据',
          value: _settings.kbEnabled,
          icon: Icons.menu_book_outlined,
          onChanged: (v) => _apply(_settings.copyWith(kbEnabled: v)),
        ),
        if (_settings.kbEnabled) ...[
          const SizedBox(height: NatsumeSpace.sm),
          _label(ac, '引用范围'),
          Wrap(
            spacing: NatsumeSpace.xs,
            runSpacing: NatsumeSpace.xs,
            children: [
              NatsumeChip(
                label: '全部知识库',
                selected: _settings.kbId == null,
                dense: true,
                onTap: () => _apply(_settings.copyWith(kbId: () => null)),
              ),
              for (final kb in _kbs)
                if (kb.id != null)
                  NatsumeChip(
                    label: kb.name,
                    selected: _settings.kbId == kb.id,
                    dense: true,
                    onTap: () => _apply(_settings.copyWith(kbId: () => kb.id)),
                  ),
            ],
          ),
          if (_kbs.isEmpty) ...[
            const SizedBox(height: NatsumeSpace.xxs),
            Text(
              '还没有知识库：先到「知识库」页导入 PDF / 笔记，小鲸才查得到。',
              style: NatsumeType.microStyle
                  .copyWith(color: ac.textTertiary, height: 1.5),
            ),
          ],
          const SizedBox(height: NatsumeSpace.xxs),
          Text(
            '引用是软约束：查不到就按通用知识回答并说明，不会编造出处。',
            style: NatsumeType.microStyle
                .copyWith(color: ac.textTertiary, height: 1.5),
          ),
        ],
      ],
    );
  }
}
