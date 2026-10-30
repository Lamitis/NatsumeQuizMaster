import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/screens/companion_screen.dart';
import 'package:natsume_quiz_master/screens/companion_settings_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/companion/companion_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/companion/companion_host.dart';

/// 悬浮小鲸（v1.33 / v1.34）的浮层契约：
/// ① 挂在 `MaterialApp.builder` 上就能跨页面常驻，头像就是 App 图标；
/// ② 能关——关悬浮 / 停插件都立刻消失（陪伴是「别打扰」，不是「关不掉」）；
/// ③ **点一下 = 戳一下**：AI 就地回话，**不再直接跳全屏页**；右键（桌面）/
///    长按（移动端）出「聊天 / 设置」，聊天是悬浮气泡输入框，设置才进二级页，
///    且同一页只压一层（连点不叠页）。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath = '${dir.path}/natsume_quiz_master/'
        'test_companion_host_${DateTime.now().microsecondsSinceEpoch}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    DatabaseService.overrideDbPath = null;
  });

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
      // 气泡定时器会让测试留下 pending timer：这一组只测浮层本身
      await appState.updateCompanionSettings(
          appState.companionSettings.copyWith(bubbleMinutes: 0));
    });
    return appState;
  }

  Widget host(AppState appState, GlobalKey<NavigatorState> navKey) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: appState),
          ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          theme: ThemeService().themeData,
          builder: (context, child) => CompanionHost(
            navigatorKey: navKey,
            rng: Random(7),
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Center(child: Text('首页'))),
        ),
      );

  /// 头像 = 复用 App 图标（`CompanionService.avatarAsset`）的那个 Image
  final avatar = find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == CompanionService.avatarAsset,
  );

  testWidgets('浮层常驻：默认显示；关掉悬浮 / 停用插件都立刻消失', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(host(appState, navKey));
    await settleFrames(tester);

    expect(find.text('首页'), findsOneWidget);
    expect(avatar, findsOneWidget);

    await tester.runAsync(() => appState.updateCompanionSettings(
        appState.companionSettings.copyWith(overlayEnabled: false)));
    await settleFrames(tester, rounds: 2);
    expect(avatar, findsNothing);
    expect(find.text('首页'), findsOneWidget, reason: '关掉浮层不能连页面一起关');

    await tester.runAsync(() async {
      await appState.updateCompanionSettings(
          appState.companionSettings.copyWith(overlayEnabled: true));
      await appState.setCompanionPluginEnabled(false);
    });
    await settleFrames(tester, rounds: 2);
    expect(avatar, findsNothing, reason: '插件停用后浮层不该还在');

    await teardownTree(tester);
  });

  testWidgets('点一下只戳一下（不跳页）；右键/长按出菜单，聊天开气泡输入框', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(host(appState, navKey));
    await settleFrames(tester);

    // ① 单击 = 戳一下：就地冒一句回话，绝不推二级页面
    await tester.tap(avatar);
    // 戳一下要读真实统计（4 次 DB 查询）再挑台词，给足真实 zone 让行
    await settleFrames(tester, rounds: 5);
    expect(find.byType(CompanionScreen), findsNothing,
        reason: 'v1.34：点一下不该直接进大界面');
    expect(find.byKey(const ValueKey('companionBubble')), findsOneWidget,
        reason: '戳一下应该在浮层里回一句');

    // ② 右键（桌面）= 菜单：聊天 / 设置（保留「今天先别出现」）
    await tester.tap(avatar, buttons: kSecondaryButton);
    await settleFrames(tester, rounds: 2);
    expect(find.text('聊天'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('今天先别出现'), findsOneWidget);

    // ③ 「聊天」= 悬浮一个气泡输入框，同样不进大界面
    await tester.tap(find.byKey(const ValueKey('companionChatMenu')));
    await settleFrames(tester, rounds: 3);
    expect(find.byKey(const ValueKey('companionChatPanel')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(CompanionScreen), findsNothing);

    // ④ 面板开着时再点头像：这句回话落在面板里（同一个窗口回话）
    await tester.tap(avatar);
    await settleFrames(tester, rounds: 2);
    expect(find.byKey(const ValueKey('companionChatPanel')), findsOneWidget);
    expect(find.byType(CompanionScreen), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('「设置」只压一层：连点不会叠出多个页面', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(host(appState, navKey));
    await settleFrames(tester);

    await tester.longPress(avatar);
    await settleFrames(tester, rounds: 2);
    await tester.tap(find.byKey(const ValueKey('companionSettingsMenu')));
    await settleFrames(tester, rounds: 4);
    expect(find.byType(CompanionSettingsScreen), findsOneWidget);

    // 页面还在栈上时再点一次「设置」：仍只有一层（旧版会叠第二页）
    await tester.longPress(avatar);
    await settleFrames(tester, rounds: 2);
    await tester.tap(find.byKey(const ValueKey('companionSettingsMenu')));
    await settleFrames(tester, rounds: 3);
    expect(find.byType(CompanionSettingsScreen), findsOneWidget);

    await teardownTree(tester);
  });
}
