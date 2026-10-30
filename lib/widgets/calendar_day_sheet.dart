import 'package:flutter/material.dart';

import '../models/schedule_item.dart';
import '../services/schedule_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import 'kit/natsume_kit.dart';


/// 日历某一天的「当日详情 + 待办」底部弹层（v1.35）。
///
/// 用户原话：日历只能看打卡，不能**提前规划**——想给下周三排个复习，
/// 得绕去「我的 → 日程待办 → 新建 → 自定义日期」。现在点日历任意一天，
/// 就地列出当天待办、加一条、勾掉一条，未来日期同样能写。
///
/// 数据层仍是 [ScheduleService]（本机保存，不进同步清单），弹层只是入口。
/// 每次改动后回调 [onChanged]，让调用页按需刷新。
Future<void> showCalendarDaySheet(
  BuildContext context, {
  required DateTime day,
  int total = 0,
  bool isVacation = false,
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _CalendarDaySheet(
      day: day,
      total: total,
      isVacation: isVacation,
      onChanged: onChanged,
    ),
  );
}

class _CalendarDaySheet extends StatefulWidget {
  const _CalendarDaySheet({
    required this.day,
    required this.total,
    required this.isVacation,
    this.onChanged,
  });

  final DateTime day;
  final int total;
  final bool isVacation;
  final VoidCallback? onChanged;

  @override
  State<_CalendarDaySheet> createState() => _CalendarDaySheetState();
}

class _CalendarDaySheetState extends State<_CalendarDaySheet> {
  final ScheduleService _service = ScheduleService.instance;
  final TextEditingController _ctrl = TextEditingController();

  List<ScheduleItem> _items = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// 新待办的默认钟点（日历只选到「哪一天」，钟点在这里补）
  int _hour = 20;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  DateTime get _dayKey =>
      DateTime(widget.day.year, widget.day.month, widget.day.day);

  Future<void> _load() async {
    try {
      final all = await _service.load();
      if (!mounted) return;
      setState(() {
        _items = ScheduleService.dueOnDay(all, widget.day);
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


  /// 顶部相对日期文案：今天 / 明天 / N 天后 / 昨天 / N 天前
  String get _relativeLabel {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = _dayKey.difference(today).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';
    if (diff > 1) return '$diff 天后';
    return '${-diff} 天前';
  }

  /// 标题：2026 年 11 月 4 日（周二）
  String get _title {
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    return '${_dayKey.year} 年 ${_dayKey.month} 月 ${_dayKey.day} 日'
        '（周${week[_dayKey.weekday - 1]}）';
  }

  void _changed() {
    widget.onChanged?.call();
  }

  Future<void> _add() async {
    final title = _ctrl.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await _service.add(
        title: title,
        dueAt: DateTime(
            _dayKey.year, _dayKey.month, _dayKey.day, _hour, 0),
      );
      if (!mounted) return;
      _ctrl.clear();
      setState(() {
        _saving = false;
      });
      await _load();
      _changed();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  Future<void> _toggle(ScheduleItem item) async {
    try {
      await _service.setDone(item, !item.done);
      if (!mounted) return;
      await _load();
      _changed();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '更新失败：$e');
    }
  }

  Future<void> _delete(ScheduleItem item) async {
    try {
      await _service.remove(item);
      if (!mounted) return;
      await _load();
      _changed();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '删除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.72;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            NatsumeSpace.lg, 0, NatsumeSpace.lg, NatsumeSpace.md + insets),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(_title,
                        style: NatsumeType.h2Style
                            .copyWith(color: ac.textPrimary)),
                  ),
                  NatsumeChip(
                      label: _relativeLabel, selected: true, dense: true),
                ],
              ),
              const SizedBox(height: NatsumeSpace.xxs),
              Text(_summaryLine(ac),
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textSecondary)),
              const SizedBox(height: NatsumeSpace.md),
              Flexible(child: _buildList(ac)),
              const SizedBox(height: NatsumeSpace.md),
              _buildAddRow(ac),
              if (_error != null) ...[
                const SizedBox(height: NatsumeSpace.xs),
                Text(_error!,
                    style: NatsumeType.microStyle.copyWith(color: ac.danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 第一行摘要：刷题量 / 假期 + 待办条数
  String _summaryLine(AppThemeColors ac) {
    final done = _items.where((e) => e.done).length;
    final todo = _items.length - done;
    final study = widget.isVacation
        ? '假期模式（不计入统计）'
        : widget.total > 0
            ? '刷题 ${widget.total} 道'
            : '当天没有刷题记录';
    return todo > 0 ? '$study · 还有 $todo 件待办' : study;
  }


  Widget _buildList(AppThemeColors ac) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.checklist_rounded, size: 16, color: ac.textTertiary),
            const SizedBox(width: NatsumeSpace.xxs),
            Text('当天待办',
                style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
            const Spacer(),
            if (!_loading)
              Text('${_items.length} 条',
                  style:
                      NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
          ],
        ),
        const SizedBox(height: NatsumeSpace.xs),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: NatsumeSpace.md),
            child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else if (_items.isEmpty)
          Text('这一天还没有安排。写一条，就落在这一天。',
              style:
                  NatsumeType.captionStyle.copyWith(color: ac.textTertiary))
        else
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _items.length; i++) ...[
                    _buildTodoRow(ac, _items[i]),
                    if (i != _items.length - 1)
                      const SizedBox(height: NatsumeSpace.xxs),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }


  Widget _buildTodoRow(AppThemeColors ac, ScheduleItem item) {
    final overdue = item.isOverdue();
    final due = item.dueAt;
    final hm = due == null
        ? ''
        : '${due.hour.toString().padLeft(2, '0')}:'
            '${due.minute.toString().padLeft(2, '0')}';
    final Color iconColor = item.done
        ? ac.success
        : overdue
            ? ac.danger
            : ac.textTertiary;
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xxs),
      child: Row(
        children: [
          // 勾选/取消勾选：整块图标区域都可点（手指友好）
          InkWell(
            borderRadius: BorderRadius.circular(NatsumeRadius.small),
            onTap: () => _toggle(item),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                item.done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: iconColor,
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
                    decoration:
                        item.done ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (hm.isNotEmpty)
                  Text(hm,
                      style: NatsumeType.microStyle.copyWith(
                          color: overdue ? ac.danger : ac.textTertiary)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: ac.textTertiary),
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            onPressed: () => _delete(item),
          ),
        ],
      ),
    );
  }

  Widget _buildAddRow(AppThemeColors ac) {
    final now = DateTime.now();
    final isFuture = _dayKey.isAfter(DateTime(now.year, now.month, now.day));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _add(),
                style: NatsumeType.bodyStyle.copyWith(color: ac.textPrimary),
                decoration: InputDecoration(
                  hintText: isFuture ? '提前安排这一天…' : '加一条待办…',
                  hintStyle:
                      NatsumeType.bodyStyle.copyWith(color: ac.textTertiary),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: NatsumeSpace.xs),
            FilledButton(
              onPressed: _saving ? null : _add,
              child: Text(_saving ? '保存中…' : '添加'),
            ),
          ],
        ),
        const SizedBox(height: NatsumeSpace.xs),
        Wrap(
          spacing: NatsumeSpace.xxs,
          runSpacing: NatsumeSpace.xxs,
          children: [
            for (final h in const [8, 12, 20, 22])
              NatsumeChip(
                label: '${h.toString().padLeft(2, '0')}:00',
                dense: true,
                selected: _hour == h,
                onTap: () => setState(() => _hour = h),
              ),
          ],
        ),
        const SizedBox(height: NatsumeSpace.xxs),
        Text('待办存在本机（不参与同步）；到期日就是这一天 $_hour:00。',
            style: NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
      ],
    );
  }
}


