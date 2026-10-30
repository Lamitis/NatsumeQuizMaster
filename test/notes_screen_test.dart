import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/notes_screen.dart';
import 'package:natsume_quiz_master/screens/profile_tab.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/notes/notes_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/note_graph_view.dart';

/// 笔记插件的界面契约（v1.31）：
/// ① 笔记页按**题库名称**分组，并明示「无法同步」；
/// ② 图谱页能画出节点/边（数据来自双链）；
/// ③ 「我的 → 学习工具」里有「双链笔记」一栏，插件停用后整栏收起。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_notes_ui_${DateTime.now().millisecondsSinceEpoch}.db';
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
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 12));
      await settleFrames(tester);
    }
    await tester.pump(const Duration(seconds: 12));
    await tester.runAsync(() => DatabaseService.instance.close());
  }

  /// 1 个题库 + 两条笔记（一条挂题库、一条未归类），两条互相双链
  Future<AppState> seed(WidgetTester tester) async {
    final appState = AppState();
    await tester.runAsync(() async {
      await appState.init();
      final db = DatabaseService.instance;
      final now = DateTime.now().toIso8601String();
      final bankId =
          await db.insertBank(QuestionBank(name: '内科学', createdAt: now));
      final service = NotesService.instance;
      await service.create(
        bankId: bankId,
        title: '缺铁性贫血',
        content: '题眼：[[铁代谢]] 紊乱，[[网织红细胞]] 升高',
      );
      await service.create(title: '游离笔记', content: '还没归类，用 #待整理 标记');
      await appState.refreshBanks();
    });
    return appState;
  }

  testWidgets('笔记页：按题库名称分组 + 顶部明示无法同步', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const NotesScreen()));
    await settleFrames(tester);

    // 分组标题 = 题库名 / 未分类
    expect(find.text('内科学'), findsOneWidget);
    expect(find.text(NotesService.ungroupedName), findsOneWidget);
    expect(find.text('缺铁性贫血'), findsOneWidget);
    expect(find.text('游离笔记'), findsOneWidget);
    // 同步边界必须在页面上看得见
    expect(find.text('无法同步'), findsOneWidget);
    expect(find.textContaining(NotesService.syncNotice), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('图谱页：节点/边来自双链，悬空页也进图', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const NotesScreen()));
    await settleFrames(tester);

    await tester.tap(find.text('图谱'));
    await settleFrames(tester, rounds: 2);

    expect(find.byType(NoteGraphView), findsOneWidget);
    // 2 条笔记 + 2 个被引用但没写过的页面（铁代谢 / 网织红细胞 / 待整理 中
    // 铁代谢与网织红细胞只被引用）→ 节点数 ≥ 3，边数 = 3
    expect(find.textContaining('个页面'), findsOneWidget);
    expect(find.textContaining('条链接'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('我的 → 学习工具：双链笔记入口随插件启停显隐', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState, const ProfileTab()));
    await settleFrames(tester);

    expect(find.text('双链笔记'), findsOneWidget);
    expect(find.textContaining('无法同步'), findsWidgets);

    await tester.runAsync(() => appState.setNotesPluginEnabled(false));
    await tester.pump();
    expect(find.text('双链笔记'), findsNothing);

    await teardownTree(tester);
  });
}
