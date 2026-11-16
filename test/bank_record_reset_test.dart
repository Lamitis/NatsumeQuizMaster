import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/answer_record.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/fsrs_service.dart';
import 'package:natsume_quiz_master/services/quiz_service.dart';

/// v1.42「重刷题库」记录契约：
/// ① 普通开始 / 继续刷题只叠加记录，**不擅自清空**；
/// ② 作答记录保留 ⇒ 题号网格红绿标记（上一次对错）可再次读到；
/// ③ 只有 `clearBankRecords` 会清该题库的 answer_records + fsrs_cards，
///    且不碰另一个题库、也不碰收藏（error_book）。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_bank_reset_');
    DatabaseService.overrideDbPath = '${tmp.path}/t.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<({int bankA, int bankB, List<int> aIds, int bId})> seed() async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankA =
        await db.insertBank(QuestionBank(name: '题库A', createdAt: now));
    final bankB =
        await db.insertBank(QuestionBank(name: '题库B', createdAt: now));

    await db.insertQuestions([
      Question(
          bankId: bankA,
          title: 'A-单选',
          options: const ['x', 'y'],
          correctAnswer: 'A',
          questionType: 'single_choice',
          createdAt: now),
      Question(
          bankId: bankA,
          title: 'A-多选',
          options: const ['x', 'y'],
          correctAnswer: 'A,B',
          questionType: 'multi_choice',
          createdAt: now),
    ]);
    await db.insertQuestions([
      Question(
          bankId: bankB,
          title: 'B-判断',
          correctAnswer: '对',
          questionType: 'true_false',
          createdAt: now),
    ]);

    final aIds =
        (await db.getQuestionsByBank(bankA)).map((q) => q.id!).toList();
    final bIds =
        (await db.getQuestionsByBank(bankB)).map((q) => q.id!).toList();
    return (bankA: bankA, bankB: bankB, aIds: aIds, bId: bIds.single);
  }

  Future<void> answer(int qid, bool correct, DateTime at) =>
      DatabaseService.instance.insertAnswerRecord(AnswerRecord(
        questionId: qid,
        userAnswer: 'A',
        isCorrect: correct,
        answeredAt: at.toIso8601String(),
      ));

  Future<void> dueCard(int qid) => DatabaseService.instance.upsertFSRSCard(
        FSRSCardState(
          questionId: qid,
          stability: 1,
          difficulty: 5,
          reviewCount: 1,
          lastReviewAt: DateTime.now(),
          nextReviewAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );

  test('上一次作答结果取最后一条（重答后按最新对错）', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    final t0 = DateTime.now().subtract(const Duration(minutes: 5));

    // A1：先错后对 → 绿；A2：先对后错 → 红；B：对
    await answer(s.aIds[0], false, t0);
    await answer(s.aIds[0], true, t0.add(const Duration(minutes: 1)));
    await answer(s.aIds[1], true, t0);
    await answer(s.aIds[1], false, t0.add(const Duration(minutes: 1)));
    await answer(s.bId, true, t0);

    final status =
        await db.getLastAnswerStatusByQuestionIds([...s.aIds, s.bId]);
    expect(status[s.aIds[0]], isTrue);
    expect(status[s.aIds[1]], isFalse);
    expect(status[s.bId], isTrue);
  });

  test('普通开始刷题不清空历史记录与红绿标记', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    final t0 = DateTime.now().subtract(const Duration(minutes: 5));
    await answer(s.aIds[0], false, t0);
    await answer(s.aIds[1], true, t0);
    await dueCard(s.aIds[0]);
    await dueCard(s.aIds[1]);

    final before = await db.getQuestionStatsByIds([...s.aIds, s.bId]);
    expect(before[s.aIds[0]]!.$1, 1);

    // 与「开始刷题 / 继续刷题」同一条路径：QuizService.startQuiz
    final quiz = QuizService();
    await quiz.startQuiz(
      bankIds: [s.bankA],
      mode: 'single',
      questionCount: 10,
      noShuffle: true,
    );
    expect(quiz.questions, isNotEmpty);

    final after = await db.getQuestionStatsByIds([...s.aIds, s.bId]);
    expect(after[s.aIds[0]]!.$1, before[s.aIds[0]]!.$1);
    expect(after[s.aIds[1]]!.$1, before[s.aIds[1]]!.$1);
    final status =
        await db.getLastAnswerStatusByQuestionIds([...s.aIds, s.bId]);
    expect(status[s.aIds[0]], isFalse);
    expect(status[s.aIds[1]], isTrue);
  });

  test('清空记录只清目标题库的作答记录与 FSRS 卡，保留收藏', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    final t0 = DateTime.now().subtract(const Duration(minutes: 5));
    // A 库：3 条作答记录 + 2 张卡；B 库：1 条记录 + 1 张卡
    await answer(s.aIds[0], false, t0);
    await answer(s.aIds[0], true, t0.add(const Duration(minutes: 1)));
    await answer(s.aIds[1], true, t0);
    await answer(s.bId, false, t0);
    for (final id in [...s.aIds, s.bId]) {
      await dueCard(id);
    }
    // 收藏是「用户标记」，重刷不应该把它一起抹掉
    await db.addToErrorBook(s.aIds[0]);

    final result = await db.clearBankRecords(s.bankA);
    expect(result.records, 3);
    expect(result.cards, 2);

    // A 的作答统计与复习卡都没了
    final stats = await db.getQuestionStatsByIds([...s.aIds, s.bId]);
    expect(stats.containsKey(s.aIds[0]), isFalse);
    expect(stats.containsKey(s.aIds[1]), isFalse);
    expect(stats[s.bId]!.$1, 1);
    expect(await db.getFSRSCard(s.aIds[0]), isNull);
    expect(await db.getFSRSCard(s.aIds[1]), isNull);
    expect(await db.getFSRSCard(s.bId), isNotNull);

    // 收藏保留：A 库仍以 bookmark 出现在错题本统计里（due 归零）
    final byBank = await db.getErrorStatsByBank();
    final a = byBank.where((r) => r['bank_id'] == s.bankA).toList();
    expect(a, hasLength(1));
    expect(a.single['due_count'], 0);
    expect(a.single['bookmark_count'], 1);
    final b = byBank.where((r) => r['bank_id'] == s.bankB).toList();
    expect(b, hasLength(1));
    expect(b.single['due_count'], 1);
  });

  test('空题库 / 不存在的题库清空返回 0', () async {
    final s = await seed();
    final result = await DatabaseService.instance.clearBankRecords(999999);
    expect(result.records, 0);
    expect(result.cards, 0);
    expect(s.bankA, isPositive);
  });
}
