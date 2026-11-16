import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/fsrs_service.dart';

/// v1.42 错题本按题型筛选：列表 / 计数 / 知识点分组 / 导出查询 / 统计条
/// 必须全部遵循同一个 `questionTypes` 条件，不能只筛列表。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_err_type_');
    DatabaseService.overrideDbPath = '${tmp.path}/t.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// q1 单选·A·到期 / q2 多选·A·到期 / q3 判断·B·到期
  /// q4 多选·B·仅收藏 / q5 单选·B·既不到期也未收藏
  Future<({int bankId, List<int> ids})> seed() async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankId =
        await db.insertBank(QuestionBank(name: '题型题库', createdAt: now));
    Future<void> add(String title, String type, String kp) =>
        db.insertQuestions([
          Question(
            bankId: bankId,
            title: title,
            options: type == 'true_false' ? const [] : const ['x', 'y'],
            correctAnswer: type == 'true_false' ? '对' : 'A',
            questionType: type,
            knowledgePoint: kp,
            createdAt: now,
          ),
        ]);
    await add('q1', 'single_choice', 'A');
    await add('q2', 'multi_choice', 'A');
    await add('q3', 'true_false', 'B');
    await add('q4', 'multi_choice', 'B');
    await add('q5', 'single_choice', 'B');

    final ids =
        (await db.getQuestionsByBank(bankId)).map((q) => q.id!).toList();
    // 前 3 题到期；第 4 题只收藏；第 5 题不在错题本
    for (final id in ids.take(3)) {
      await db.upsertFSRSCard(FSRSCardState(
        questionId: id,
        stability: 1,
        difficulty: 5,
        reviewCount: 1,
        lastReviewAt: DateTime.now(),
        nextReviewAt: DateTime.now().subtract(const Duration(days: 1)),
      ));
    }
    await db.addToErrorBook(ids[3]);
    return (bankId: bankId, ids: ids);
  }

  test('错题列表与计数按题型收窄', () async {
    final s = await seed();
    final db = DatabaseService.instance;

    final multi = await db
        .getFullErrorQuestions('wrong', questionTypes: {'multi_choice'});
    expect(multi.map((q) => q.id).toSet(), {s.ids[1]});
    expect(await db.getFullErrorCount('wrong', questionTypes: {'multi_choice'}),
        1);

    final choices = await db.getFullErrorQuestions('wrong',
        questionTypes: {'single_choice', 'multi_choice'});
    expect(choices.map((q) => q.id).toSet(), {s.ids[0], s.ids[1]});
    expect(
      await db.getFullErrorCount('wrong',
          questionTypes: {'single_choice', 'multi_choice'}),
      2,
    );

    // 不限题型 = 老行为（零回归）
    expect(await db.getFullErrorCount('wrong'), 3);
    final all = await db.getFullErrorQuestions('all');
    expect(
        all.map((q) => q.id).toSet(), {s.ids[0], s.ids[1], s.ids[2], s.ids[3]});
  });

  test('题型可与题库条件叠加', () async {
    final s = await seed();
    final db = DatabaseService.instance;
    expect(
      await db.getFullErrorCount('wrong',
          bankIds: {s.bankId}, questionTypes: {'true_false'}),
      1,
    );
    expect(
      await db.getFullErrorCount('wrong',
          bankIds: {999999}, questionTypes: {'true_false'}),
      0,
    );
  });

  test('知识点分组按题型收窄（数量与取题同口径）', () async {
    final s = await seed();
    final db = DatabaseService.instance;

    final byKpAll = await db.getKnowledgePointStats('wrong');
    expect({for (final r in byKpAll) r['kp'] as String: r['cnt'] as int},
        {'A': 2, 'B': 1});

    final byKpMulti = await db
        .getKnowledgePointStats('wrong', questionTypes: {'multi_choice'});
    expect({for (final r in byKpMulti) r['kp'] as String: r['cnt'] as int},
        {'A': 1});

    final picked = await db.getFullQuestionsByKnowledgePoint('A', 'wrong',
        questionTypes: {'single_choice'});
    expect(picked.map((q) => q.id).toSet(), {s.ids[0]});

    final pickedAll = await db.getFullQuestionsByKnowledgePoint('A', 'wrong');
    expect(pickedAll.map((q) => q.id).toSet(), {s.ids[0], s.ids[1]});
  });

  test('导出查询（带统计）同样遵循题型条件', () async {
    final s = await seed();
    final db = DatabaseService.instance;

    final rows = await db
        .getErrorQuestionsWithStats('all', questionTypes: {'multi_choice'});
    expect(rows.map((r) => r['id'] as int).toSet(), {s.ids[1], s.ids[3]});
    expect(rows.every((r) => r['question_type'] == 'multi_choice'), isTrue);

    // 自定义选题 + 题型：两者取交集
    final picked = await db.getErrorQuestionsWithStats(
      'all',
      questionIds: {s.ids[1], s.ids[2]},
      questionTypes: {'true_false'},
    );
    expect(picked.map((r) => r['id'] as int).toSet(), {s.ids[2]});
  });

  test('错题本统计条（按题库）也按题型收窄', () async {
    final s = await seed();
    final db = DatabaseService.instance;

    final allStats = await db.getErrorStatsByBank();
    expect(allStats.single['due_count'], 3);
    expect(allStats.single['bookmark_count'], 1);

    final multiStats =
        await db.getErrorStatsByBank(questionTypes: {'multi_choice'});
    expect(multiStats.single['due_count'], 1); // q2
    expect(multiStats.single['bookmark_count'], 1); // q4
    expect(s.bankId, isPositive);
  });
}
