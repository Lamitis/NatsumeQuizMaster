import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/fsrs_service.dart';

/// 错题本删减（v1.34.1）：
///
/// 「错题本」= FSRS 到期卡 ∪ 收藏，所以只删收藏是不够的——到期错题还得
/// 连同复习卡一起清掉。契约：
/// 1. 移除后两种口径都不再出现该题；
/// 2. 题库里的题目、历史作答记录保留（不是删题）；
/// 3. 以后再次答错，题目回到错题本；
/// 4. 批量移除只影响本机收藏，不会误伤别的题。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_error_book_remove_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
  });

  /// 4 道题：q1 到期 + 收藏 / q2 到期 / q3 收藏 / q4 干净
  Future<(int, List<int>)> seed() async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankId =
        await db.insertBank(QuestionBank(name: '错题库', createdAt: now));
    for (var i = 1; i <= 4; i++) {
      await db.insertQuestions([
        Question(bankId: bankId, title: 'q$i', correctAnswer: 'A', createdAt: now),
      ]);
    }
    final ids = (await db.getQuestionsByBank(bankId)).map((q) => q.id!).toList();
    await db.updateBankQuestionCount(bankId, ids.length);
    await db.addToErrorBook(ids[0]);
    await db.addToErrorBook(ids[2]);
    for (final id in [ids[0], ids[1]]) {
      await db.upsertFSRSCard(FSRSCardState(
        questionId: id,
        stability: 1,
        difficulty: 5,
        reviewCount: 1,
        lastReviewAt: DateTime.now(),
        nextReviewAt: DateTime.now().subtract(const Duration(days: 1)),
      ));
    }
    return (bankId, ids);
  }

  test('移除到期错题：清复习卡，题目与题库计数都不动', () async {
    final (bankId, ids) = await seed();
    final db = DatabaseService.instance;
    expect(await db.getFullErrorCount('wrong'), 2);

    expect(await db.removeQuestionsFromErrorBook([ids[1]]), 1);

    expect(await db.getFullErrorCount('wrong'), 1, reason: 'q2 已移出');
    expect(await db.getFSRSCard(ids[1]), isNull);
    expect((await db.getQuestionsByBank(bankId)).length, 4, reason: '题目不能被删');
    expect((await db.getAllBanks()).single.questionCount, 4);
  });

  test('移除收藏题：清本机收藏（all / bookmark 口径同步收窄）', () async {
    final (_, ids) = await seed();
    final db = DatabaseService.instance;
    expect(await db.getFullErrorCount('all'), 3);

    await db.removeQuestionsFromErrorBook([ids[2]]);

    expect(await db.getFullErrorCount('bookmark'), 1, reason: '只剩 q1');
    expect(await db.getFullErrorCount('all'), 2, reason: 'q1 到期+收藏 / q2 到期');
    expect(await db.isInErrorBook(ids[2]), isFalse);
  });

  test('批量移除混合来源：一次清掉两张卡与两处收藏', () async {
    final (_, ids) = await seed();
    final db = DatabaseService.instance;

    expect(await db.removeQuestionsFromErrorBook([ids[0], ids[1], ids[2]]), 3);

    expect(await db.getFullErrorCount('all'), 0);
    expect(await db.getFullErrorCount('wrong'), 0);
    expect(await db.getFullErrorCount('bookmark'), 0);
    // 重复移除是幂等的
    expect(await db.removeQuestionsFromErrorBook([ids[0]]), 1);
    expect(await db.getFullErrorCount('all'), 0);
  });

  test('以后再次答错会重新回到错题本', () async {
    final (_, ids) = await seed();
    final db = DatabaseService.instance;
    await db.removeQuestionsFromErrorBook([ids[1]]);
    expect(await db.getFullErrorCount('wrong'), 1);

    await db.upsertFSRSCard(FSRSService.initCard(ids[1], DateTime.now()));

    expect(await db.getFullErrorCount('wrong'), 2);
  });

  test('应用层 removeQuestionsFromErrorBook：返回移除数并刷新统计', () async {
    final (_, ids) = await seed();
    final appState = AppState();
    await appState.init();

    expect(await appState.removeQuestionsFromErrorBook([ids[0], ids[1]]), 2);

    final db = DatabaseService.instance;
    expect(await db.getFullErrorCount('all'), 1); // 只剩收藏的 q3
    expect(await db.getFullErrorCount('wrong'), 0);
    // 空集合直接返回 0，不查库也不报错
    expect(await appState.removeQuestionsFromErrorBook(const []), 0);
  });
}
