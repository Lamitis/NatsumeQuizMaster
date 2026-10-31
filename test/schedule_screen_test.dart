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
    // 先把路径指到临时库，再关上一个用例的残留连接：`close()` 在内部
    // `_database` 为空时会顺手 open 一次**当前路径**的库，先设好 overrideDbPath
    // 才能保证它不会去碰用户真正的 natsume.db。
    final dir = Directory.systemTemp.createTempSync('natsume_schedule_ui_');
    DatabaseService.overrideDbPath = '${dir.path}/schedule_ui.db';
    await DatabaseService.instance.close();

    // 建库 + 迁移（`openDatabase(onCreate:)` 是一个事务，几十条 execute）
    // 放在 setUp 里跑：setUp 走的是**真实异步**，不受 testWidgets 的假时钟
    // 影响。留在用例里做的话，慢机器上首屏会一直转圈——见 waitUntil 的注释。
    await DatabaseService.instance.database;
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

  /// 等**真实异步**（sqflite 的 isolate）推进到某个界面状态为止。
  ///
  /// 为什么不靠固定帧数：`_load()` 走真库，`openDatabase` 的建表/迁移是一个
  /// 事务，要在独立 isolate 上跑几十条 `execute`，只有 `runAsync` 给的真实时间
  /// 才会推进它；`settleFrames` 的 150ms 在本机够用，在慢机器（CI）上不够。
  ///
  /// 为什么更不能用 `pumpAndSettle()`：它只推进**假时钟**，并且要求「没有帧被
  /// 调度」才返回。首屏还停在 `CircularProgressIndicator` 时，转圈动画永远在
  /// 调度帧，它就空转到 10 分钟假时间后抛「pumpAndSettle timed out」；而这期间
  /// 真库那边拿不到真实时间、事务一直不结束，于是刷屏
  /// 「database has been locked for 0:00:10」——「pumpAndSettle timed out」+
  /// 那把锁就是这么来的，不是弹窗里有死循环动画。
  ///
  /// 所以这里「真实时间 20ms + 假时钟 10ms」交替推进，并且**允许页面上有动画
  /// 在跑**。超时前顺带把 `tester.takeException()` 捞出来，比只报「没等到」好查。
  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 30),
    String? reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        final err = tester.takeException();
        fail('等待超时（${timeout.inSeconds}s）：${reason ?? '目标状态未出现'}'
            '${err == null ? '' : '\n期间捕获到的异常：$err'}');
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 首屏读完（真库查询 + setState 都收尾，转圈消失）。
  ///
  /// 所有「点开页面后马上断言/马上点开弹窗」的用例都先过这一关：转圈没消失就
  /// 去交互，等于踩上面那个 pumpAndSettle 的坑。
  Future<void> waitLoaded(WidgetTester tester) async {
    await waitUntil(
      tester,
      () =>
          find.byType(CircularProgressIndicator).evaluate().isEmpty ||
          find.text('读取失败').evaluate().isNotEmpty,
      reason: '首屏一直停在加载转圈（真库 open/建表没跑完，或查询卡住）',
    );
    expect(find.text('读取失败'), findsNothing,
        reason: '首屏读取待办时抛异常了（看 _error 文案）');
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
    await waitLoaded(tester);

    expect(find.text('日程待办'), findsOneWidget);
    expect(find.textContaining('随局域网同步'), findsWidgets);
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
    await waitLoaded(tester);

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
    await waitLoaded(tester);
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
    // 先等首屏读完再开弹窗：还在转圈时开，弹窗底下那个转圈动画会让
    // 「等界面静下来」永远等不到（原因见 waitUntil 注释）。
    await waitLoaded(tester);

    // 空状态与工具栏都有「新建待办」，点工具栏那个（带 + 图标）
    await tester.tap(find.byIcon(Icons.add_rounded).first);
    // 不用 pumpAndSettle()：它只推假时钟、要求「没有帧被调度」，一旦页面上
    // 还有转圈就会空转到超时；这里直接等弹窗内容出现（弹窗只是纯表单，
    // 开弹窗不碰数据库，见 _ScheduleEditorDialog 的注释）。
    await waitUntil(
      tester,
      () => find.text('要做什么').evaluate().isNotEmpty,
      reason: '点了「新建待办」后弹窗没出现',
    );

    expect(find.text('要做什么'), findsOneWidget);
    final createBtn =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '创建'));
    expect(createBtn.onPressed, isNull, reason: '标题为空不该能创建');

    await tester.enterText(find.byType(TextField).first, '  背诵 20 个生化酶  ');
    await tester.pump();
    await tester.tap(find.text('无期限'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    // 落库（insert）+ 重新 `_load()`（open 之后的 query）都是真异步，
    // 固定帧数在慢机器上不够：等列表里真的出现这条再说。
    await waitUntil(
      tester,
      () => find.text('背诵 20 个生化酶').evaluate().isNotEmpty,
      reason: '新建后列表里没出现「背诵 20 个生化酶」'
          '（落库或新建后的重新加载没完成）',
    );

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
    await waitLoaded(tester);

    expect(find.text('今天没有待办'), findsOneWidget);
    expect(find.text('暂无待办 · 随局域网同步（可在设置里关掉）'), findsOneWidget);

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
    await waitLoaded(tester);
    expect(find.text('宽屏也要显示'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await teardownTree(tester);
  });
}
