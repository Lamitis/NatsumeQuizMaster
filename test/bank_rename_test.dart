import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// 题库改名（v1.34.1）：导入后的题库必须能改名字。
///
/// 此前题库管理页只支持「分类」改名，题库卡上压根没有重命名入口，
/// 用户只能用导入时的文件名当题库名。这里钉住数据层 + 应用层的契约：
/// 改名只动名字，题目照旧；空名 / 重名被拒绝且不写库。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_bank_rename_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
  });

  Future<int> seed(String name, int count) async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankId = await db.insertBank(QuestionBank(name: name, createdAt: now));
    await db.insertQuestions([
      for (var i = 1; i <= count; i++)
        Question(
            bankId: bankId,
            title: '$name-题$i',
            correctAnswer: 'A',
            options: const ['A', 'B', 'C'],
            createdAt: now),
    ]);
    await db.updateBankQuestionCount(bankId, count);
    return bankId;
  }

  test('数据层 renameBank：只改名字，题目数量与题目内容不变', () async {
    final db = DatabaseService.instance;
    final bankId = await seed('原名题库', 2);

    await db.renameBank(bankId, '改后的题库');

    final banks = await db.getAllBanks();
    expect(banks.single.name, '改后的题库');
    expect(banks.single.questionCount, 2);
    expect((await db.getQuestionsByBank(bankId)).length, 2);
  });

  test('应用层 renameBank：成功后题库列表立即刷新', () async {
    final appState = AppState();
    await appState.init();
    final bankId = await seed('导入文件名', 1);
    await appState.refreshBanks();

    expect(await appState.renameBank(bankId, '  病理学错题  '), isNull);
    expect(appState.banks.single.name, '病理学错题');
    expect(appState.banks.single.questionCount, 1);
  });

  test('空名 / 重名被拒绝，且不写库', () async {
    final appState = AppState();
    await appState.init();
    final first = await seed('题库一', 1);
    final second = await seed('题库二', 1);
    await appState.refreshBanks();

    expect(await appState.renameBank(first, '   '), '题库名不能为空');
    expect(await appState.renameBank(first, '题库二'), contains('已存在同名题库'));
    expect(appState.banks.map((b) => b.name), containsAll(['题库一', '题库二']));

    // 只改大小写/空格后的名字，重名判定按 trim 后的结果
    expect(await appState.renameBank(second, ' 题库二 '), isNull,
        reason: '名字没变（仅首尾空格）不算失败');
    expect(appState.banks.map((b) => b.name), containsAll(['题库一', '题库二']));

    // 不存在的题库
    expect(await appState.renameBank(99999, '随便'), '题库不存在');
  });
}
