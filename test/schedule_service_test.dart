import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/schedule_item.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/plugins/builtin_plugins.dart';
import 'package:natsume_quiz_master/services/schedule_service.dart';

/// 日程待办插件（v1.34 / schema v16）：排序、到期文案、今日待办计数、数据层。
///
/// 这些口径必须集中钉死：列表、徽章、入口提示共用同一套纯函数，一旦
/// 「列表说今天到期、徽章却说 0 件」用户就再也不信这个插件了。
void main() {
  /// 固定「现在」，避免测试在凌晨/午夜边界上抖动
  final now = DateTime(2026, 10, 29, 11, 30);

  ScheduleItem item({
    int? id,
    String title = '待办',
    DateTime? dueAt,
    bool done = false,
    String updatedAt = '2026-10-29T09:00:00.000',
  }) =>
      ScheduleItem(
        id: id,
        title: title,
        dueAt: dueAt,
        done: done,
        createdAt: '2026-10-01T09:00:00.000',
        updatedAt: updatedAt,
      );

  group('到期文案', () {
    test('无期限 / 今天 / 明天 / 昨天', () {
      expect(ScheduleService.dueText(null, now: now), '无期限');
      expect(ScheduleService.dueText(DateTime(2026, 10, 29, 20, 5), now: now),
          '今天 20:05');
      expect(ScheduleService.dueText(DateTime(2026, 10, 30, 8, 0), now: now),
          '明天 08:00');
      expect(ScheduleService.dueText(DateTime(2026, 10, 28, 23, 59), now: now),
          '昨天 23:59');
    });

    test('逾期按天数说话（负号转成「逾期 N 天」）', () {
      expect(ScheduleService.dueText(DateTime(2026, 10, 27, 9, 0), now: now),
          '逾期 2 天');
    });

    test('一周内说「N 天后」，更远说日期', () {
      expect(ScheduleService.dueText(DateTime(2026, 11, 2, 7, 0), now: now),
          '4 天后 07:00');
      expect(ScheduleService.dueText(DateTime(2026, 11, 20, 7, 0), now: now),
          '11月20日 07:00');
      // 跨年补年份，否则「1月5日」分不出是哪一年
      expect(ScheduleService.dueText(DateTime(2027, 1, 5, 7, 0), now: now),
          '2027/1/5 07:00');
    });

    test('跨天判断按日历日，不看小时差', () {
      // 距 now 只有 1 小时，但已经是第二天 00:30
      expect(ScheduleService.dueText(DateTime(2026, 10, 30, 0, 30), now: now),
          '明天 00:30');
    });
  });

  group('今日待办计数', () {
    test('今天到期 + 逾期未做都算，未来与无期限不算', () {
      final items = [
        item(id: 1, dueAt: DateTime(2026, 10, 29, 20, 0)), // 今天
        item(id: 2, dueAt: DateTime(2026, 10, 20, 20, 0)), // 逾期 9 天
        item(id: 3, dueAt: DateTime(2026, 11, 5, 20, 0)), // 未来
        item(id: 4), // 无期限
      ];
      expect(ScheduleService.dueTodayCount(items, now: now), 2);
    });

    test('已完成的不再计数', () {
      final items = [
        item(id: 1, dueAt: DateTime(2026, 10, 29, 20, 0), done: true),
        item(id: 2, dueAt: DateTime(2026, 10, 20, 20, 0), done: true),
        item(id: 3, dueAt: DateTime(2026, 10, 29, 8, 0)), // 今天未做
      ];
      expect(ScheduleService.dueTodayCount(items, now: now), 1);
    });

    test('空列表是 0（入口不显示红点）', () {
      expect(ScheduleService.dueTodayCount(const [], now: now), 0);
    });
  });

  group('列表排序', () {
    test('未完成在前，到期近的优先，无期限沉底', () {
      final items = [
        item(id: 1, title: '无期限'),
        item(id: 2, title: '下周', dueAt: DateTime(2026, 11, 5, 9, 0)),
        item(id: 3, title: '今天', dueAt: DateTime(2026, 10, 29, 20, 0)),
        item(id: 4, title: '已完成', done: true),
      ];
      final sorted = ScheduleService.sorted(items, now: now);
      expect(sorted.map((e) => e.title).toList(),
          ['今天', '下周', '无期限', '已完成']);
    });

    test('已完成按更新时间倒序（刚勾掉的排最前）', () {
      final items = [
        item(id: 1, title: '早完成', done: true, updatedAt: '2026-10-28T09:00:00.000'),
        item(id: 2, title: '刚完成', done: true, updatedAt: '2026-10-29T10:00:00.000'),
      ];
      final sorted = ScheduleService.sorted(items, now: now);
      expect(sorted.first.title, '刚完成');
    });

    test('同一到期时间按 id 升序，结果稳定不抖动', () {
      final due = DateTime(2026, 10, 29, 20, 0);
      final items = [
        item(id: 9, title: 'b', dueAt: due),
        item(id: 3, title: 'a', dueAt: due),
      ];
      expect(ScheduleService.sorted(items, now: now).map((e) => e.id).toList(),
          [3, 9]);
      // 反过来喂一遍也是同一结果（排序不能依赖输入顺序）
      expect(
          ScheduleService.sorted(items.reversed.toList(), now: now)
              .map((e) => e.id)
              .toList(),
          [3, 9]);
    });

    test('不改动传入列表（纯函数，列表与徽章可共用）', () {
      final items = [
        item(id: 1, title: '无期限'),
        item(id: 2, title: '今天', dueAt: DateTime(2026, 10, 29, 20, 0)),
      ];
      ScheduleService.sorted(items, now: now);
      expect(items.first.title, '无期限');
    });
  });

  group('逾期标记', () {
    test('未完成且到期时间已过才算逾期', () {
      expect(item(dueAt: DateTime(2026, 10, 28, 9, 0)).isOverdue(now: now), isTrue);
      expect(item(dueAt: DateTime(2026, 10, 29, 20, 0)).isOverdue(now: now),
          isFalse);
      expect(
          item(dueAt: DateTime(2026, 10, 28, 9, 0), done: true)
              .isOverdue(now: now),
          isFalse);
      expect(item().isOverdue(now: now), isFalse); // 无期限永远不算逾期
    });
  });

  group('copyWith 的 dueAt 语义', () {
    test('不传 dueAt 表示「不改」', () {
      final it = item(dueAt: DateTime(2026, 10, 29, 20, 0));
      expect(it.copyWith(title: '改名').dueAt, it.dueAt);
    });

    test('clearDue 才是「清空到期时间」', () {
      final it = item(dueAt: DateTime(2026, 10, 29, 20, 0));
      expect(it.copyWith(clearDue: true).dueAt, isNull);
    });
  });

  group('数据层（v16 schedule_items 表）', () {
    setUp(() async {
      await DatabaseService.instance.close();
      final dir = Directory.systemTemp.createTempSync('natsume_schedule_');
      DatabaseService.overrideDbPath = '${dir.path}/schedule.db';
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
    });

    test('日程插件不可同步（插件数据本机保存）', () {
      expect(BuiltinPlugins.schedule.syncable, isFalse);
      expect(BuiltinPlugins.schedule.manifestMap['syncable'], isFalse);
    });

    test('增删改查：新建 → 勾选 → 删除', () async {
      final service = ScheduleService.instance;
      final id = await service.add(
        title: '  过一遍 FSRS 今日到期  ',
        detail: '60 题',
        dueAt: DateTime(2026, 10, 30, 20, 0),
      );
      expect(id, greaterThan(0));

      var items = await service.load(now: now);
      expect(items.length, 1);
      // 标题两端空白要去掉（否则列表里看着像缩进）
      expect(items.single.title, '过一遍 FSRS 今日到期');
      expect(items.single.detail, '60 题');
      expect(items.single.done, isFalse);

      await service.setDone(items.single, true);
      items = await service.load(now: now);
      expect(items.single.done, isTrue);

      await service.remove(items.single);
      expect(await service.load(now: now), isEmpty);
    });

    test('改标题与到期时间会落库（updatedAt 由服务层刷新）', () async {
      final service = ScheduleService.instance;
      final id = await service.add(title: '旧标题');
      final created = await DatabaseService.instance.getScheduleItem(id);

      await service.update(
          created!.copyWith(title: '新标题', dueAt: DateTime(2026, 11, 1, 8, 0)));
      final after = await DatabaseService.instance.getScheduleItem(id);
      expect(after!.title, '新标题');
      expect(after.dueAt, DateTime(2026, 11, 1, 8, 0));
      expect(after.updatedAt, isNot(created.updatedAt));
    });

    test('勾选后再取消勾选能回到未完成', () async {
      final service = ScheduleService.instance;
      await service.add(title: '可撤销的勾选');
      var items = await service.load(now: now);
      await service.setDone(items.single, true);
      items = await service.load(now: now);
      await service.setDone(items.single, false);
      items = await service.load(now: now);
      expect(items.single.done, isFalse);
    });

    test('load 返回的结果已按「未完成在前」排好序', () async {
      final service = ScheduleService.instance;
      await service.add(title: '无期限');
      await service.add(title: '明天', dueAt: DateTime(2026, 10, 30, 8, 0));
      await service.add(title: '今天', dueAt: DateTime(2026, 10, 29, 20, 0));

      final items = await service.load(now: now);
      expect(items.map((e) => e.title).toList(), ['今天', '明天', '无期限']);
    });
  });
}
