import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/screens/knowledge_point_types_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 「知识点体系」编辑页（v1.35）的界面契约：
/// ① 默认空体系 = AI 自行判断，页面必须说清楚（不能让用户以为坏了）；
/// ② 新增 → 列表立刻出现、计数跟着变；
/// ③ 保存后落到设置里（空列表也能保存 = 恢复默认）。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath = '${dir.path}/natsume_quiz_master/'
        'test_kp_types_ui_${DateTime.now().microsecondsSinceEpoch}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    DatabaseService.overrideDbPath = null;
  });

  Widget host(AppState appState) => MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: appState),
          ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
        ],
        child: MaterialApp(
          theme: ThemeService().themeData,
          home: const KnowledgePointTypesScreen(),
        ),
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
    await tester.runAsync(() => DatabaseService.instance.close());
  }

  Future<AppState> seed(WidgetTester tester) async {
    final appState = AppState();
    await tester.runAsync(() async {
      await appState.init();
    });
    return appState;
  }

  testWidgets('空体系有明确说明；新增两条后保存进设置', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState));
    await settleFrames(tester);

    expect(appState.settings.knowledgePointTypes, isEmpty);
    expect(find.text('还没有条目：AI 会自行判断知识点。'), findsOneWidget);
    expect(find.text('0 类'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '呼吸系统');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '循环系统');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();

    expect(find.text('2 类'), findsOneWidget);
    // 还没保存：设置里仍是空的
    expect(appState.settings.knowledgePointTypes, isEmpty);

    await tester.tap(find.text('保存知识点体系'));
    await settleFrames(tester);

    expect(appState.settings.knowledgePointTypes, ['呼吸系统', '循环系统']);

    await teardownTree(tester);
  });

  testWidgets('清空后保存 = 交回 AI 判断（空列表是合法状态）', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.runAsync(
        () => appState.setKnowledgePointTypes(['解剖学', '生理学']));

    await tester.pumpWidget(host(appState));
    await settleFrames(tester);
    expect(find.text('2 类'), findsOneWidget);

    await tester.tap(find.text('清空（交回 AI 判断）'));
    await tester.pump();
    expect(find.text('0 类'), findsOneWidget);

    await tester.tap(find.text('保存知识点体系'));
    await settleFrames(tester);

    expect(appState.settings.knowledgePointTypes, isEmpty);

    await teardownTree(tester);
  });
}
