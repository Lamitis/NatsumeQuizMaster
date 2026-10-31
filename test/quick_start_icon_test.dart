import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/screens/quick_start_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 功能名是「自由选题」，图标是「框里一个『自』字」，
/// 不再使用 assets/burst_icon_ui.png 那张「爆」字素材。
///
/// 这条测试守住两件事：
///   ① 卡片文案已是「自由选题」（旧名「定向爆破」不再出现）；
///   ② 图标是文字「自」，且不再渲染 burst 素材图片。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_qs_icon_${DateTime.now().millisecondsSinceEpoch}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    DatabaseService.overrideDbPath = null;
  });

  Future<void> settleFrames(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('「自由选题」卡片用「自」字方块图标，不再用「爆」字素材', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final appState = AppState();
    await tester.runAsync(() => appState.init());

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
      ],
      child: MaterialApp(
        theme: ThemeService().themeData,
        home: const QuickStartScreen(),
      ),
    ));
    await settleFrames(tester);

    expect(find.text('自由选题'), findsOneWidget);
    expect(find.text('定向爆破'), findsNothing);

    // ① 旧素材不该再出现（换回 burst 图片即视为回归）
    expect(find.byIcon(Icons.rocket_launch_rounded), findsNothing,
        reason: '已改为「自」字方块图标，不该再用火箭图标');
    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
        images.where((i) =>
            i.image is AssetImage &&
            (i.image as AssetImage).assetName == 'assets/burst_icon_ui.png'),
        isEmpty,
        reason: '「自由选题」不再使用「爆」字素材');

    // ② 图标就是「自」字
    expect(find.text('自'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => DatabaseService.instance.close());
  });
}

