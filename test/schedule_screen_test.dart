import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/screens/schedule_screen.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/schedule_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 日程待办插件的界面契约（v1.34）：
/// ① 360dp 窄屏铺得下（工具栏换行、行内不溢出）；
/// ② 页面上直说「本机保存（无法同步）」，别让用户同步完才发现没带过去；
/// ③ 勾选就地生效并落库，筛选能分开看待办/已完成；
/// ④ 新建弹窗在窄屏也不溢出，标题为空时不能创建。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory.systemTemp.createTempSync('natsume_schedule_ui_');
    DatabaseService.overrideDbPath = '${dir.path}/schedule_ui.db';
  });

  tearDown(() async {
    DatabaseService.overrideDbPath = null;
  });

  Widget host({bool dark = false}) => MaterialApp(
        theme: ThemeService().themeData,
        home: const ScheduleScreen(),
      );

  /// 360dp × 640dp：Android 小屏竖屏（横向溢出在这里最容易暴露）
  void setPhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// 真库操作在真实异步里跑，界面帧要手动推（sqflite_common_ffi 的 Future
  /// 不会因为 pump 而完成，必须配 runAsync 放行）
  Future<void> settleFrames(WidgetTester tester, {int rounds = 3}) async {
    for (var r = 0; r < rounds; r++) {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settleFrames(tester);
    await tester.runAsync(() => DatabaseService.instance.close());
  }

  testWidgets('360dp 窄屏能铺下：无溢出，并写明「无法同步」', (tester) async {
    setPhoneSurface(tester);
    await tester.runAsync(() async {
      final s = ScheduleService.instance;
      final now = DateTime.now();
      // 一条逾期、一条今天到期（都要出现在首屏）
      await s.add(
        title: '过一遍 FSRS 今日到期的 60 道题',
        detail: '内科 30 题 + 外科 30 题',
        dueAt: DateTime(now.year, now.month, now.day, 20, 0),
      );
      await s.add(
        title: '补写昨日错题笔记',
        dueAt: now.subtract(const Duration(days: 3)),
      );
    });

    await tester.pumpWidget(host());
    await settleFrames(tester);

    expect(find.text('日程待办'), findsOneWidget);
    expect(find.textContaining('无法同步'), findsWidgets);
    expect(find.textContaining('逾期'), findsWidgets);
    expect(tester.takeException(), isNull);

    await teardownTree(tester);
  });

  testWidgets('勾选就地完成并落库（完成后沉底）', (tester) async {
    setPhoneSurface(tester);
    await tester.runAsync(() async {
      await ScheduleService.instance.add(
        title: '今天要勾掉的事',
        dueAt: DateTime.now().add(const Duration(hours: 2)),
      );
    });

    await tester.pumpWidget(host());
    await settleFrames(tester);

    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded).first);
    await settleFrames(tester);

    final items = await tester.runAsync(
        () => DatabaseService.instance.getScheduleItems());
    expect(items!.single.done, isTrue);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('筛选：切到「已完成」只剩勾掉的那些', (tester) async {
    setPhoneSurface(tester);
    await tester.runAsync(() async {
      final s = ScheduleService.instance;
      final id = await s.add(title: '还没做的事');
      await s.add(title: '已经做完的事');
      final done =
          (await DatabaseService.instance.getScheduleItems()).firstWhere((e) =>
              e.title == '已经做完的事');
      await s.setDone(done, true);
      expect(id, greaterThan(0));
    });

    await tester.pumpWidget(host());
    await settleFrames(tester);
    expect(find.text('还没做的事'), findsOneWidget);
    expect(find.text('已经做完的事'), findsOneWidget);

    await tester.tap(find.text('已完成'));
    await settleFrames(tester);
    expect(find.text('已经做完的事'), findsOneWidget);
    expect(find.text('还没做的事'), findsNothing);

    await tester.tap(find.text('待办'));
    await settleFrames(tester);
    expect(find.text('还没做的事'), findsOneWidget);
    expect(find.text('已经做完的事'), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('新建弹窗：窄屏不溢出，标题为空时不能创建', (tester) async {
    setPhoneSurface(tester);
    await tester.pumpWidget(host());
    await settleFrames(tester);

    // 空状态与工具栏都有「新建待办」，点工具栏那个（带 + 图标）
    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('要做什么'), findsOneWidget);
    final createBtn =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '创建'));
    expect(createBtn.onPressed, isNull, reason: '标题为空不该能创建');

    await tester.enterText(find.byType(TextField).first, '  背诵 20 个生化酶  ');
    await tester.pump();
    await tester.tap(find.text('无期限'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await settleFrames(tester);

    // 标题两端空白被去掉，且作为「无期限」进列表
    expect(find.text('背诵 20 个生化酶'), findsOneWidget);
    expect(find.textContaining('无期限'), findsWidgets);
    expect(tester.takeException(), isNull);

    final items = await tester.runAsync(
        () => DatabaseService.instance.getScheduleItems());
    expect(items!.single.title, '背诵 20 个生化酶');
    expect(items.single.dueAt, isNull);

    await teardownTree(tester);
  });

  testWidgets('一条都没有时给「今天没有待办」和一键新建', (tester) async {
    setPhoneSurface(tester);
    await tester.pumpWidget(host());
    await settleFrames(tester);

    expect(find.text('今天没有待办'), findsOneWidget);
    expect(find.text('暂无待办 · 本机保存（无法同步）'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('宽屏（900dp）同样正常：内容限宽不铺满', (tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.runAsync(() async {
      await ScheduleService.instance.add(title: '宽屏也要显示');
    });

    await tester.pumpWidget(host());
    await settleFrames(tester);
    expect(find.text('宽屏也要显示'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await teardownTree(tester);
  });
}
