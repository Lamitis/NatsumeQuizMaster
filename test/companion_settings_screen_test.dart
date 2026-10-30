import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/models/companion.dart';
import 'package:natsume_quiz_master/models/companion_settings.dart';
import 'package:natsume_quiz_master/screens/companion_settings_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/companion/companion_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 「助教设置」页（v1.33）的界面契约：
/// ① 五个分区都在，默认「跟随软件」时不逼用户再填一遍 Key；
/// ② 开关 / 分段控件**即时生效**（立刻写回 AppState 并落盘），不需要点保存；
/// ③ 文本框改完点「保存设置」才落库，保存后有明确提示；
/// ④ 「今天先别出现」可只撤回这一天，不顺手关掉悬浮母开关。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath = '${dir.path}/natsume_quiz_master/'
        'test_companion_settings_ui_${DateTime.now().microsecondsSinceEpoch}.db';
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

  /// 设置页是长列表：目标可能在视区外还没建出来，先滚到位再断言
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      240,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    await tester.pump();
  }

  testWidgets('分区齐全（含助教形象）；默认跟随软件，不逼用户填第二遍 Key', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const CompanionSettingsScreen()));
    await settleFrames(tester);

    // v1.35：形象选择排在最前（用户反馈在 AI 设置里找不到换头像的地方）
    expect(find.text('助教形象'), findsOneWidget);
    expect(find.byKey(const ValueKey('companionAvatarChoice-navy')),
        findsOneWidget);
    expect(find.text('悬浮小鲸'), findsOneWidget);

    await scrollTo(tester, find.text('人格设定'));
    expect(find.text('人格设定'), findsOneWidget);
    await scrollTo(tester, find.text('记忆'));
    expect(find.text('记忆'), findsOneWidget);

    await scrollTo(tester, find.text('AI 接口'));
    expect(find.text('AI 接口'), findsOneWidget);
    // 跟随软件：只显示当前配置概要，不出现独立配置的 Key 输入框
    expect(find.text('软件未配置 Key'), findsOneWidget);
    expect(find.textContaining('API Key（本机加密保存）'), findsNothing);

    await scrollTo(tester, find.text('知识库'));
    expect(find.text('知识库'), findsOneWidget);
    // 页面底部把同步边界讲清楚：人设/记忆可同步，Key 与好感度仍本机
    expect(find.textContaining('API Key、好感度与悬浮位置只留本机'), findsWidgets);

    await teardownTree(tester);
  });

  testWidgets('语气切换即时生效并落盘（不用点保存）', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const CompanionSettingsScreen()));
    await settleFrames(tester);

    await tester.ensureVisible(find.text(CompanionTone.strict.label));
    await tester.pump();
    await tester.tap(find.text(CompanionTone.strict.label));
    await settleFrames(tester, rounds: 3);

    expect(appState.companionSettings.tone, CompanionTone.strict);
    expect(find.text(CompanionTone.strict.hint), findsOneWidget);
    final saved = await tester
        .runAsync(() => CompanionService.instance.loadSettings());
    expect(saved!.tone, CompanionTone.strict);

    await teardownTree(tester);
  });

  testWidgets('角色名走「保存设置」：改完点保存才落库并有提示', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const CompanionSettingsScreen()));
    await settleFrames(tester);

    // 第一个输入框是「角色名」（默认显示 hint「小鲸」）
    await tester.enterText(find.byType(TextField).first, '溟月');
    await tester.pump();
    // 还没保存：内存里的设置不该被文本改动污染
    expect(appState.companionSettings.displayName, '小鲸');

    final save = find.text('保存设置');
    await scrollTo(tester, save);
    await tester.tap(save);
    await settleFrames(tester, rounds: 3);

    expect(appState.companionSettings.displayName, '溟月');
    expect(find.text('助教设置已保存'), findsOneWidget);
    final saved = await tester
        .runAsync(() => CompanionService.instance.loadSettings());
    expect(saved!.displayName, '溟月');

    await teardownTree(tester);
  });

  testWidgets('「今天先别出现」只撤回这一天，母开关保持原状', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.runAsync(() => appState.updateCompanionSettings(
          appState.companionSettings.copyWith(
            hiddenDay: () => companionDayKey(DateTime.now()),
          ),
        ));
    await tester.pumpWidget(host(appState, const CompanionSettingsScreen()));
    await settleFrames(tester);

    expect(find.text('今天已被请走'), findsOneWidget);
    await scrollTo(tester, find.text('让她回来'));
    await tester.tap(find.text('让她回来'));
    await settleFrames(tester, rounds: 3);

    expect(appState.companionSettings.hiddenDay, isNull);
    // 悬浮母开关不该被「请回来」顺手关掉
    expect(appState.companionSettings.overlayEnabled, isTrue);
    expect(find.text('今天已被请走'), findsNothing);

    await teardownTree(tester);
  });
}
