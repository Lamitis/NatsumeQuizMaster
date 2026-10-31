import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/bank_questions_screen.dart';
import 'package:natsume_quiz_master/screens/practice_screen.dart';
import 'package:natsume_quiz_master/screens/quiz_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 从「管理题库」点进某个题库后，先看到**日历式题号方块**
/// （方框里只有题号），上方可选「正常刷题 / 练习 / 背题」，点题号即以该模式
/// 从这道题开始刷这个题库；这套「选题量/模式再开刷」的逻辑与自由选题共用。
///
/// 这里锁住三件事：
/// ① 进题库默认是题号网格 + 三种模式都可见；
/// ② 点题号后抽题范围就是该题库、顺序与原题库一致（题号 = 题序），
///    并且从点中的那道题开始；
/// ③ 练习/背题不落库、正常刷题落库（与自由选题同一套 [QuizLauncher] 行为）。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_bank_grid_${DateTime.now().millisecondsSinceEpoch}.db';
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

  /// 有限帧推进 + 真实 zone 让行：sqflite ffi 的真实异步在假异步 zone 里
  /// 不会自己前进，必须用 runAsync 放行（同 wide_layout_test 的 settleFrames）
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

  /// 建 1 个题库 + 12 道题（题目顺序 = 题号顺序）
  Future<(QuestionBank, AppState)> seed(WidgetTester tester) async {
    final appState = AppState();
    late QuestionBank bank;
    await tester.runAsync(() async {
      await appState.init();
      final db = DatabaseService.instance;
      final now = DateTime.now().toIso8601String();
      final bankId =
          await db.insertBank(QuestionBank(name: '内科学', createdAt: now));
      await db.insertQuestions([
        for (var i = 1; i <= 12; i++)
          Question(
            bankId: bankId,
            title: '题$i',
            options: const ['选项一', '选项二'],
            correctAnswer: 'A',
            createdAt: now,
          ),
      ]);
      await db.updateBankQuestionCount(bankId, 12);
      await appState.refreshBanks();
      bank = appState.banks.firstWhere((b) => b.id == bankId);
    });
    return (bank, appState);
  }

  testWidgets('进题库默认是题号网格：方框只有题号，上方可选三种模式', (tester) async {
    setSurface(tester);
    final (bank, appState) = await seed(tester);
    await tester.pumpWidget(host(appState, BankQuestionsScreen(bank: bank)));
    await settleFrames(tester);

    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('12 道题目 · 点题号开始刷题'), findsOneWidget);
    // 题号方块：1..12 都渲染出来
    for (final n in const [1, 3, 7, 12]) {
      expect(find.text('$n'), findsOneWidget, reason: '缺少题号 $n');
    }
    // 三种模式
    expect(find.text('正常刷题'), findsOneWidget);
    expect(find.text('练习'), findsOneWidget);
    expect(find.text('背题模式'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('练习模式点题号：只抽该库、顺序一致、从该题开始且不落库', (tester) async {
    setSurface(tester);
    final (bank, appState) = await seed(tester);
    await tester.pumpWidget(host(appState, BankQuestionsScreen(bank: bank)));
    await settleFrames(tester);

    await tester.tap(find.text('练习'));
    await settleFrames(tester, rounds: 1);
    await tester.tap(find.text('3'));
    await settleFrames(tester, rounds: 5);

    expect(appState.quizQuestions.length, 12);
    // 题号 = 题库原始顺序（noShuffle），否则点第 3 个方块未必是第 3 题
    expect(appState.quizQuestions[2].title, '题3');
    expect(appState.currentQuestionIndex, 2);
    // 练习模式零落库（会话 id 为空）
    expect(appState.currentSession?.id, isNull);
    expect(find.byType(PracticeEntryScreen), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('正常刷题点题号：抽该库并从该题开始，会话落库', (tester) async {
    setSurface(tester);
    final (bank, appState) = await seed(tester);
    await tester.pumpWidget(host(appState, BankQuestionsScreen(bank: bank)));
    await settleFrames(tester);

    await tester.tap(find.text('5'));
    // 正常刷题要落库（会话 + 会话题序 + 题库关联，多次串行 DB 往返），
    // 比练习模式多好几轮 runAsync 放行
    await settleFrames(tester, rounds: 14);

    expect(appState.quizQuestions[4].title, '题5');
    expect(appState.currentQuestionIndex, 4);
    expect(appState.currentSession?.id, isNotNull);
    expect(find.byType(QuizScreen), findsOneWidget);

    await teardownTree(tester);
  });
}
