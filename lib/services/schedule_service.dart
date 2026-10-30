import '../models/schedule_item.dart';
import 'database_service.dart';

/// 日程待办插件的数据层（v16）。
///
/// 插件边界与双链笔记一致：**本机保存、不进同步导出清单**，所以这里除了
/// 增删改查不碰任何同步状态；界面上必须写明「无法同步」。
///
/// 排序与文案都是 `static` 纯函数：列表、徽章、测试共用同一份口径，
/// 免得「列表说今天到期、通知说逾期」这种自相矛盾。
class ScheduleService {
  ScheduleService._();

  static final ScheduleService instance = ScheduleService._();

  final DatabaseService _db = DatabaseService.instance;

  /// 取待办（含已完成），按「未完成优先 → 到期近的在前 → 无期限最后」排序
  Future<List<ScheduleItem>> load({DateTime? now}) async {
    final items = await _db.getScheduleItems();
    return sorted(items, now: now);
  }

  Future<int> add({
    required String title,
    String detail = '',
    DateTime? dueAt,
  }) async {
    final now = DateTime.now().toIso8601String();
    return _db.insertScheduleItem(ScheduleItem(
      title: title.trim(),
      detail: detail.trim(),
      dueAt: dueAt,
      createdAt: now,
      updatedAt: now,
    ));
  }

  Future<void> update(ScheduleItem item) async {
    await _db.updateScheduleItem(item.copyWith(
      updatedAt: DateTime.now().toIso8601String(),
    ));
  }

  /// 勾选/取消勾选（只改完成态与时间戳）
  Future<void> setDone(ScheduleItem item, bool done) async {
    if (item.id == null) return;
    await update(item.copyWith(done: done));
  }

  Future<void> remove(ScheduleItem item) async {
    if (item.id == null) return;
    await _db.deleteScheduleItem(item.id!);
  }

  /// 今天到期的（含已逾期未完成）——首页/入口徽章用
  static int dueTodayCount(List<ScheduleItem> items, {DateTime? now}) {
    final n = now ?? DateTime.now();
    var count = 0;
    for (final item in items) {
      if (item.done || item.dueAt == null) continue;
      final due = item.dueAt!;
      if (due.year == n.year && due.month == n.month && due.day == n.day) {
        count++;
      } else if (due.isBefore(DateTime(n.year, n.month, n.day))) {
        // 逾期未做的也算「今天该处理」
        count++;
      }
    }
    return count;
  }

  /// 某一天到期的待办（v1.35 日历点选某天用）。
  ///
  /// 只比年月日：日历点的是「哪一天」，具体几点由列表自己显示；
  /// 无期限待办不落在任何一天，所以不算进来。
  static List<ScheduleItem> dueOnDay(List<ScheduleItem> items, DateTime day) {
    return [
      for (final item in items)
        if (item.dueAt != null &&
            item.dueAt!.year == day.year &&
            item.dueAt!.month == day.month &&
            item.dueAt!.day == day.day)
          item
    ];
  }

  /// 列表排序：未完成在前（到期近的优先，无期限沉底），已完成按更新时间倒序
  static List<ScheduleItem> sorted(List<ScheduleItem> items, {DateTime? now}) {
    final list = List<ScheduleItem>.of(items);
    list.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.done) return b.updatedAt.compareTo(a.updatedAt);
      if (a.dueAt == null && b.dueAt == null) {
        return (b.id ?? 0).compareTo(a.id ?? 0);
      }
      if (a.dueAt == null) return 1;
      if (b.dueAt == null) return -1;
      final cmp = a.dueAt!.compareTo(b.dueAt!);
      if (cmp != 0) return cmp;
      return (a.id ?? 0).compareTo(b.id ?? 0);
    });
    return list;
  }

  /// 到期文案：今天/明天/昨天/逾期 N 天/几月几号，集中在这里避免各页各写一套。
  static String dueText(DateTime? due, {DateTime? now}) {
    if (due == null) return '无期限';
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final day = DateTime(due.year, due.month, due.day);
    final diff = day.difference(today).inDays;
    final hm = '${due.hour.toString().padLeft(2, '0')}:'
        '${due.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '明天 $hm';
    if (diff == -1) return '昨天 $hm';
    if (diff < -1) return '逾期 ${-diff} 天';
    if (diff <= 7) return '$diff 天后 $hm';
    if (due.year == n.year) return '${due.month}月${due.day}日 $hm';
    return '${due.year}/${due.month}/${due.day} $hm';
  }
}
