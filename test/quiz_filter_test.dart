import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/utils/app_constants.dart';
import 'package:natsume_quiz_master/widgets/quiz_setup_sheet.dart';

/// 2026-10-29 用户反馈：自由选题面板要能直接勾选**题库范围 + 知识点**，
/// 不必先回「管理题库」重勾一遍。
///
/// 这里钉住四层口径：
/// ① `getQuestionsByBanks` 的筛选真的收窄结果，空集合仍等价整库；
/// ② 「未分类」（空知识点）只有显式勾选才纳入，不会被默认筛掉；
/// ③ `getKnowledgePointsByBanks` 的计数与题数一致（含未分类、排除 AI 失败标记）；
/// ④ `startQuizWithFilter` 筛到 0 题时不建会话（不污染历史与统计）。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    // 每个测试文件用独立库文件（多文件并行时互不干扰）
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_quiz_filter_${DateTime.now().millisecondsSinceEpoch}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
  });

  /// 两个题库：
  /// - A（生理学）：3 道「血液」+ 2 道「生化」+ 1 道无知识点（未分类）
  /// - B（病理学）：2 道「血液」（多选）+ 1 道 AI 失败标记
  Future<(int, int)> seed() async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final a = await db.insertBank(QuestionBank(name: '生理学', createdAt: now));
    final b = await db.insertBank(QuestionBank(name: '病理学', createdAt: now));
    await db.insertQuestions([
      for (var i = 0; i < 3; i++)
        Question(
            bankId: a,
            title: 'A血液$i',
            options: const ['甲', '乙'],
            correctAnswer: 'A',
            knowledgePoint: '血液',
            createdAt: now),
      for (var i = 0; i < 2; i++)
        Question(
            bankId: a,
            title: 'A生化$i',
            options: const ['甲', '乙'],
            correctAnswer: 'A',
            knowledgePoint: '生化',
            createdAt: now),
      Question(
          bankId: a,
          title: 'A未分类',
          options: const ['甲', '乙'],
          correctAnswer: 'A',
          createdAt: now),
      for (var i = 0; i < 2; i++)
        Question(
            bankId: b,
            title: 'B血液$i',
            options: const ['甲', '乙', '丙'],
            correctAnswer: 'A,C',
            questionType: 'multi_choice',
            knowledgePoint: '血液',
            createdAt: now),
      Question(
          bankId: b,
          title: 'B失败标记',
          options: const ['甲', '乙'],
          correctAnswer: 'A',
          knowledgePoint: 'AI请求失败：超时',
          createdAt: now),
    ]);
    await db.updateBankQuestionCount(a, 6);
    await db.updateBankQuestionCount(b, 3);
    return (a, b);
  }

  test('知识点筛选只取命中的题；空集合仍是整库', () async {
    final (a, b) = await seed();
    final db = DatabaseService.instance;

    expect((await db.getQuestionsByBanks([a, b])).length, 9);

    final blood =
        await db.getQuestionsByBanks([a, b], knowledgePoints: {'血液'});
    expect(blood.length, 5);
    expect(blood.every((q) => q.knowledgePoint == '血液'), isTrue);

    // 只在 A 库里筛「生化」：B 库没有该知识点，不会串库
    final bio = await db.getQuestionsByBanks([a], knowledgePoints: {'生化'});
    expect(bio.map((q) => q.title).toSet(), {'A生化0', 'A生化1'});
  });

  test('「未分类」是显式选项：勾它才纳入无知识点题', () async {
    final (a, _) = await seed();
    final db = DatabaseService.instance;

    final untagged =
        await db.getQuestionsByBanks([a], knowledgePoints: {''});
    expect(untagged.map((q) => q.title).toList(), ['A未分类']);

    // 「血液」+「未分类」= 3 + 1
    final mixed =
        await db.getQuestionsByBanks([a], knowledgePoints: {'血液', ''});
    expect(mixed.length, 4);
  });

  test('题型筛选、题量与「顺序出题」一起生效', () async {
    final (a, b) = await seed();
    final db = DatabaseService.instance;

    final multi =
        await db.getQuestionsByBanks([a, b], questionTypes: {'multi_choice'});
    expect(multi.length, 2);
    expect(multi.every((q) => q.questionType == 'multi_choice'), isTrue);

    expect((await db.getQuestionsByBanks([a, b], limit: 4)).length, 4);

    // 顺序模式按插入顺序：题号 = 题序（题库题号网格依赖这一点）
    final ordered =
        await db.getQuestionsByBanks([a], random: false, limit: 3);
    expect(ordered.map((q) => q.title).toList(), ['A血液0', 'A血液1', 'A血液2']);
  });

  test('getKnowledgePointsByBanks：计数正确、未分类为空串、排除 AI 失败标记',
      () async {
    final (a, b) = await seed();
    final db = DatabaseService.instance;

    final stats = await db.getKnowledgePointsByBanks([a, b]);
    final byKp = {for (final s in stats) s['kp'] as String: s['cnt'] as int};
    expect(byKp['血液'], 5); // A 里 3 + B 里 2
    expect(byKp['生化'], 2);
    expect(byKp[''], 1); // A 的未分类题
    expect(byKp.containsKey('AI请求失败：超时'), isFalse);

    final onlyB = await db.getKnowledgePointsByBanks([b]);
    expect({for (final s in onlyB) s['kp'] as String: s['cnt'] as int},
        {'血液': 2});

    expect(await db.getKnowledgePointsByBanks(const []), isEmpty);
  });

  test('startQuizWithFilter：按知识点抽题并落库', () async {
    final (a, b) = await seed();
    final app = AppState();
    await app.init();

    await app.startQuizWithFilter(
      bankIds: {a, b},
      count: kQuestionCountAll,
      knowledgePoints: {'生化'},
    );
    expect(app.quizQuestions.length, 2);
    expect(app.quizQuestions.every((q) => q.knowledgePoint == '生化'), isTrue);
    expect(app.currentSession, isNotNull);
    expect(app.currentSession!.totalQuestions, 2);
  });

  test('startQuizWithFilter：筛到 0 题不建会话（沿用防空会话逻辑）', () async {
    final (a, _) = await seed();
    final app = AppState();
    await app.init();

    await app.startQuizWithFilter(
      bankIds: {a},
      count: 10,
      knowledgePoints: {'不存在的知识点'},
    );
    expect(app.quizQuestions, isEmpty);
    expect(app.currentSession, isNull);
  });

  test('startQuizWith（无筛选）行为不变：整库抽题', () async {
    final (a, _) = await seed();
    final app = AppState();
    await app.init();

    await app.startQuizWith(bankIds: {a}, count: kQuestionCountAll);
    expect(app.quizQuestions.length, 6);
  });

  /// 有限帧推进 + 真实 zone 让行：sqflite ffi 的真实异步在假异步 zone 里
  /// 不会自己前进，必须用 runAsync 放行（同 bank_question_grid_test）
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

  testWidgets('面板：勾了知识点再点「开始」，筛选条件随结果交回', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final (a, _) = await seed();
    final app = AppState();
    await tester.runAsync(() => app.init());
    app.toggleBankSelection(a); // 面板默认范围 = 开始页已勾选的库

    QuizSetupResult? result;
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
      ],
      child: MaterialApp(
        theme: ThemeService().themeData,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await QuizSetupSheet.show(context, app);
                },
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开面板'));
    await settleFrames(tester);
    expect(find.text('自由选题'), findsOneWidget);

    // 知识点随题库联动加载（异步读库 → 再一帧才出现）
    await settleFrames(tester, rounds: 2);
    final kpChip = find.text('生化 · 2');
    expect(kpChip, findsOneWidget, reason: '知识点列表应来自所选题库');
    await tester.ensureVisible(kpChip);
    await tester.tap(kpChip);
    await settleFrames(tester, rounds: 1);

    // 题型筛选（v1.34 补齐面板入口）：勾「多选」
    final typeChip = find.text('多选');
    await tester.ensureVisible(typeChip);
    await tester.tap(typeChip);
    await settleFrames(tester, rounds: 1);

    final start = find.text('开始');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await settleFrames(tester, rounds: 2);

    expect(result, isNotNull);
    expect(result!.knowledgePoints, {'生化'});
    expect(result!.questionTypes, {'multi_choice'});
    expect(result!.bankIds, {a});
    expect(result!.count, app.selectedQuestionCount);
    expect(result!.mode.name, 'quiz');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => DatabaseService.instance.close());
  });
}
