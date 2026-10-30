import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/screens/companion_screen.dart';
import 'package:natsume_quiz_master/screens/profile_tab.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/companion/companion_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/companion/companion_avatar.dart';

/// 「小鲸助教」的界面契约（v1.32）：
/// ① 页头有自绘头像、真实统计与「无法同步」，不会假装能同步；
/// ② 未配置 AI 时也能对话（固定文案），好感度随互动增长；
/// ③ 「我的 → 学习工具」入口随插件启停显隐。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath = '${dir.path}/natsume_quiz_master/'
        'test_companion_ui_${DateTime.now().microsecondsSinceEpoch}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    DatabaseService.overrideDbPath = null;
  });

  Widget host(AppState appState, Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: appState),
          ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
        ],
        child: MaterialApp(theme: ThemeService().themeData, home: child),
      );

  void setSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> settleFrames(WidgetTester tester, {int rounds = 6}) async {
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
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 12));
      await settleFrames(tester);
    }
    await tester.pump(const Duration(seconds: 12));
    await tester.runAsync(() => DatabaseService.instance.close());
  }

  Future<AppState> seed(WidgetTester tester) async {
    final appState = AppState();
    await tester.runAsync(() async {
      await appState.init();
    });
    return appState;
  }

  testWidgets('陪伴页：自绘头像 + 真实统计 + 同步状态', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const CompanionScreen()));
    await settleFrames(tester);

    expect(find.byType(CompanionAvatar), findsWidgets);
    expect(find.textContaining(CompanionService.personaName), findsWidgets);
    expect(find.text('人设可同步'), findsOneWidget);
    expect(find.text(CompanionService.syncNotice), findsOneWidget);
    // 统计标签即使全 0 也要展示（bot 说话的依据是同一组数字）
    expect(find.text('连续打卡 0 天'), findsOneWidget);
    expect(find.text('待复习 0'), findsOneWidget);
    // 开场白已就位（气泡不是空的）
    expect(find.textContaining('小鲸'), findsWidgets);

    await teardownTree(tester);
  });

  testWidgets('没配 AI Key 也能聊：固定文案 + 好感度增长', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const CompanionScreen()));
    await settleFrames(tester);

    expect(appState.settings.isConfigured, isFalse);
    await tester.ensureVisible(find.text('夸夸我'));
    await tester.tap(find.text('夸夸我'));
    await settleFrames(tester, rounds: 8);

    // 用户这句已上屏
    expect(find.text('夸夸我'), findsWidgets);
    // 兜底回复里带真实数字（0 题也要说实话，而不是空夸）
    expect(find.textContaining('从 0 到 1'), findsOneWidget);
    // 未配置 AI 的说明必须出现，避免用户以为在跟模型对话
    expect(find.textContaining('未配置 AI 接口'), findsOneWidget);
    // 每天第一次互动 +3
    expect(find.textContaining('好感度 3'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('我的 → 学习工具：小鲸助教 / 日程待办入口随插件启停显隐', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const ProfileTab()));
    await settleFrames(tester);

    // 入口在长列表里，先滚到能看见为止（ListView 只构建可视区内元素）
    Future<void> scrollTo(String label) async {
      await tester.scrollUntilVisible(
        find.text(label),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settleFrames(tester);
    }

    await scrollTo('小鲸助教');
    expect(find.text('小鲸助教'), findsOneWidget);
    expect(find.textContaining('人设与记忆可同步'), findsWidgets);

    // v1.34 日程插件同样有入口，且同样标注本机保存
    await scrollTo('日程待办');
    expect(find.text('日程待办'), findsOneWidget);

    await tester.runAsync(() => appState.setCompanionPluginEnabled(false));
    await tester.pump();
    expect(find.text('小鲸助教'), findsNothing);

    await tester.runAsync(() => appState.setSchedulePluginEnabled(false));
    await tester.pump();
    expect(find.text('日程待办'), findsNothing);

    await teardownTree(tester);
  });
}
