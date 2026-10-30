import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/plugin_sync_scope.dart';
import '../models/schedule_item.dart';
import '../services/app_state.dart';
import '../services/schedule_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

/// 日程待办（v1.34 · 日程插件）——「我的 → 学习工具 → 日程待办」的落点。
///
/// 定位：把复习计划落成**能勾掉的待办**，而不是又一个日历。所以只有三件事：
///   1. 按到期日排期（今天到期 / 逾期未做排最前，无期限沉底）；
///   2. 勾选完成（就地改，不跳页）；
///   3. 逾期标红（一眼看出欠账）。
///
/// 同步边界与双链笔记一致：待办存本地 `schedule_items` 表（schema v16/v17），
/// v1.35 起随局域网同步（按 uid 合并），页面上跟着开关显示「随局域网同步」
/// 或「仅本机」——用户点进来之前就该知道，而不是同步完才发现没带过去。
///
/// 手机适配：整页 `ResponsivePage` 限宽 + 工具栏 [Wrap] 折行，
/// 行内标题单行省略、到期标签不换行，360dp 宽也不会溢出。
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

/// 列表筛选
enum _ScheduleFilter { all, todo, done }

class _ScheduleScreenState extends State<ScheduleScreen> {
  final ScheduleService _service = ScheduleService.instance;

  List<ScheduleItem> _items = [];
  bool _loading = true;
  String? _error;
  _ScheduleFilter _filter = _ScheduleFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _service.load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<ScheduleItem> get _visible {
    switch (_filter) {
      case _ScheduleFilter.all:
        return _items;
      case _ScheduleFilter.todo:
        return _items.where((e) => !e.done).toList();
      case _ScheduleFilter.done:
        return _items.where((e) => e.done).toList();
    }
  }

  int get _todoCount => _items.where((e) => !e.done).length;

  /// 待办是否参与局域网同步（v1.35：设置页可关；读不到设置就当开）
  bool _syncOn(BuildContext context) {
    try {
      return context
          .watch<AppState>()
          .isPluginSyncEnabled(PluginSyncScope.schedulePluginId);
    } catch (_) {
      // 测试里可能没挂 Provider：按默认（开启）显示，不让文案把页面打崩
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('日程待办'),
        actions: [
          NatsumeIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onPressed: _load,
          ),
          const SizedBox(width: NatsumeSpace.xs),
        ],
      ),
      body: ResponsivePage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(context),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  /// 工具栏：筛选分段 + 新建。窄屏时自动换行（Wrap），不做横向滚动。
  Widget _buildToolbar(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          NatsumeSpace.md, NatsumeSpace.md, NatsumeSpace.md, NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: NatsumeSpace.sm,
            runSpacing: NatsumeSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              NatsumeSegmentedControl<_ScheduleFilter>(
                segments: const [
                  (_ScheduleFilter.all, '全部'),
                  (_ScheduleFilter.todo, '待办'),
                  (_ScheduleFilter.done, '已完成'),
                ],
                value: _filter,
                onChanged: (v) => setState(() => _filter = v),
                dense: true,
              ),
              NatsumeButton(
                label: '新建待办',
                icon: Icons.add_rounded,
                onPressed: () => _openEditor(),
              ),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xs),
          Text(
            // 同步边界写在这里：看列表时就能看到，不用去翻插件说明。
            // v1.35：跟着「插件内容同步」开关走，开/关都说清楚。
            '${_todoCount == 0 ? '暂无待办' : '还有 $_todoCount 件事'}'
            ' · ${_syncOn(context) ? '随局域网同步（可在设置里关掉）' : '仅本机（同步已关闭）'}',
            style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return NatsumeEmptyState(
        icon: Icons.error_outline_rounded,
        title: '读取失败',
        description: _error,
        action: NatsumeButton(label: '重试', onPressed: _load),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return NatsumeEmptyState(
        icon: Icons.event_available_outlined,
        title: _filter == _ScheduleFilter.done ? '还没有完成的事项' : '今天没有待办',
        description: _filter == _ScheduleFilter.done
            ? '勾掉一件待办后会出现在这里，方便回看进度。'
            : '把「今晚过一遍 FSRS 到期的题」这类计划拆成待办，勾掉比记住更靠谱。',
        action: NatsumeButton(
          label: '新建待办',
          icon: Icons.add_rounded,
          onPressed: () => _openEditor(),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
          NatsumeSpace.md, 0, NatsumeSpace.md, NatsumeSpace.xl),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: NatsumeSpace.xs),
      itemBuilder: (context, index) => _buildRow(context, visible[index]),
    );
  }

  Widget _buildRow(BuildContext context, ScheduleItem item) {
    final ac = AppThemeColors.of(context);
    final overdue = item.isOverdue();
    return NatsumeSurface(
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 勾选框：命中区域给足（手机上别让人点三次才勾上）
          InkResponse(
            onTap: () => _toggle(item),
            radius: 22,
            child: Padding(
              padding: const EdgeInsets.all(NatsumeSpace.xxs),
              child: Icon(
                item.done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: item.done ? ac.success : ac.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: NatsumeSpace.xxs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NatsumeType.bodyStyle.copyWith(
                    color: item.done ? ac.textTertiary : ac.textPrimary,
                    decoration: item.done ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (item.detail.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textSecondary),
                  ),
                ],
                const SizedBox(height: NatsumeSpace.xxs),
                Wrap(
                  spacing: NatsumeSpace.xxs,
                  runSpacing: NatsumeSpace.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    NatsumeTag(
                      ScheduleService.dueText(item.dueAt),
                      tone: item.done
                          ? NatsumeTagTone.neutral
                          : (overdue
                              ? NatsumeTagTone.danger
                              : NatsumeTagTone.accent),
                    ),
                    if (overdue) const NatsumeTag('逾期'),
                  ],
                ),
              ],
            ),
          ),
          // 编辑 / 删除收进菜单：行内只留勾选一个主操作
          PopupMenuButton<String>(
            icon:
                Icon(Icons.more_horiz_rounded, size: 18, color: ac.textTertiary),
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'edit') {
                _openEditor(item: item);
              } else if (value == 'delete') {
                _confirmDelete(item);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  /// 勾选 / 取消勾选：先就地生效（勾选要立刻有反馈），落库失败再回滚提示
  Future<void> _toggle(ScheduleItem item) async {
    final before = List<ScheduleItem>.of(_items);
    final updated = item.copyWith(done: !item.done);
    setState(() {
      // 完成态变了，排序规则也变了（已完成沉底）：重排一次，别等刷新
      _items = ScheduleService.sorted([
        for (final e in _items) e.id == item.id ? updated : e,
      ]);
    });
    try {
      await _service.setDone(item, updated.done);
    } catch (e) {
      if (!mounted) return;
      setState(() => _items = before);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  /// 新建 / 编辑待办
  Future<void> _openEditor({ScheduleItem? item}) async {
    final draft = await showDialog<_ScheduleDraft>(
      context: context,
      builder: (_) => _ScheduleEditorDialog(initial: item),
    );
    if (draft == null || !mounted) return;
    try {
      if (item == null) {
        await _service.add(
            title: draft.title, detail: draft.detail, dueAt: draft.dueAt);
      } else {
        await _service.update(item.copyWith(
          title: draft.title,
          detail: draft.detail,
          dueAt: draft.dueAt,
          clearDue: draft.dueAt == null,
        ));
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  /// 删除确认：待办删了没有回收站，必须先问一句
  Future<void> _confirmDelete(ScheduleItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除待办'),
        content: Text('确定删除「${item.title}」？删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _service.remove(item);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }
}

/// 编辑弹窗返回值（标题必填；dueAt == null 表示无期限）
class _ScheduleDraft {
  final String title;
  final String detail;
  final DateTime? dueAt;

  const _ScheduleDraft(this.title, this.detail, this.dueAt);
}

/// 新建 / 编辑待办的弹窗。
///
/// 只在**保存**时回传草稿（[_ScheduleDraft]），落库交给页面统一处理：
/// 弹窗不碰数据库，测试里也就不用为了校验表单起一个真库。
class _ScheduleEditorDialog extends StatefulWidget {
  const _ScheduleEditorDialog({this.initial});

  /// null ⇒ 新建
  final ScheduleItem? initial;

  @override
  State<_ScheduleEditorDialog> createState() => _ScheduleEditorDialogState();
}

class _ScheduleEditorDialogState extends State<_ScheduleEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _detail;
  DateTime? _dueAt;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _title = TextEditingController(text: initial?.title ?? '');
    _detail = TextEditingController(text: initial?.detail ?? '');
    _dueAt = initial?.dueAt;
  }

  @override
  void dispose() {
    _title.dispose();
    _detail.dispose();
    super.dispose();
  }

  bool get _canSave => _title.text.trim().isNotEmpty;

  /// 相对今天的某个整点（快捷到期用）：今晚 20:00 / 明晚 20:00
  DateTime _at(int addDays, int hour) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, hour)
        .add(Duration(days: addDays));
  }

  Future<void> _pickDateTime() async {
    final base = _dueAt ?? DateTime.now();
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      // 允许往前选：补录昨天没做完的事也很常见
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: '选择到期日期',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      helpText: '选择到期时间',
    );
    if (!mounted) return;
    final h = time?.hour ?? base.hour;
    final m = time?.minute ?? base.minute;
    setState(() => _dueAt = DateTime(date.year, date.month, date.day, h, m));
  }

  void _save() {
    if (!_canSave) return;
    Navigator.pop(
      context,
      _ScheduleDraft(_title.text.trim(), _detail.text.trim(), _dueAt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? '编辑待办' : '新建待办'),
      content: SizedBox(
        width: dialogContentWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                autofocus: !editing,
                textInputAction: TextInputAction.next,
                maxLength: 80,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '要做什么',
                  hintText: '例如：过一遍 FSRS 今日到期的 60 题',
                  counterText: '',
                ),
              ),
              const SizedBox(height: NatsumeSpace.sm),
              TextField(
                controller: _detail,
                maxLines: 3,
                minLines: 1,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '范围、资料来源、截止规则…',
                  counterText: '',
                ),
              ),
              const SizedBox(height: NatsumeSpace.md),
              Text('到期时间',
                  style: NatsumeType.captionStyle.copyWith(
                      fontWeight: FontWeight.w600, color: ac.textSecondary)),
              const SizedBox(height: NatsumeSpace.xs),
              Wrap(
                spacing: NatsumeSpace.xxs,
                runSpacing: NatsumeSpace.xxs,
                children: [
                  NatsumeChip(
                    label: '今晚 20:00',
                    dense: true,
                    selected: false,
                    onTap: () => setState(() => _dueAt = _at(0, 20)),
                  ),
                  NatsumeChip(
                    label: '明晚 20:00',
                    dense: true,
                    selected: false,
                    onTap: () => setState(() => _dueAt = _at(1, 20)),
                  ),
                  NatsumeChip(
                    label: '三天后',
                    dense: true,
                    selected: false,
                    onTap: () => setState(() => _dueAt = _at(3, 20)),
                  ),
                  NatsumeChip(
                    label: '无期限',
                    dense: true,
                    selected: _dueAt == null,
                    onTap: () => setState(() => _dueAt = null),
                  ),
                  NatsumeChip(
                    label: '自定义…',
                    dense: true,
                    selected: false,
                    onTap: _pickDateTime,
                  ),
                ],
              ),
              const SizedBox(height: NatsumeSpace.xs),
              Text(
                _dueAt == null
                    ? '无期限：随时可做，不参与逾期判断'
                    : '到期：${ScheduleService.dueText(_dueAt)}',
                style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: Text(editing ? '保存' : '创建'),
        ),
      ],
    );
  }
}
