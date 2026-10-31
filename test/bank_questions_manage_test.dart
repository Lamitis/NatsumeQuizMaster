import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/models/question_image.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';

/// 「导入之后还能改」（v1.30.2）
///
/// 编辑不只在导入过程中可用：导入完毕之后也能进管理题库改 / 删 / 移已导入的
/// 题目（知识库同理）。
/// 这里锁定数据层的四件事：
/// ① 移动题目后两个库的题数都重算（题库卡读的就是 question_count）；
/// ② 删题连带清掉配图/作答记录/错题本/复习卡，题数同步；
/// ③ 知识库文档可重命名；
/// ④ 文档可跨库移动，文本块跟着走（旧库检索不到已搬走的内容）。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    final base = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dir = Directory('${base.path}/natsume_quiz_master');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    tmp = Directory.systemTemp.createTempSync('natsume_manage_');
    DatabaseService.overrideDbPath = '${dir.path}/test_bank_manage.db';
    final dbFile = File(DatabaseService.overrideDbPath!);
    if (dbFile.existsSync()) dbFile.deleteSync();
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Question question(int bankId, String title, {List<QuestionImage> images = const []}) =>
      Question(
        bankId: bankId,
        title: title,
        options: const ['选项一', '选项二'],
        correctAnswer: 'A',
        createdAt: DateTime.now().toIso8601String(),
        images: images,
      );

  test('移动题目：两库题数同步重算，题目归属改变', () async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankA = await db.insertBank(QuestionBank(name: 'A库', createdAt: now));
    final bankB = await db.insertBank(QuestionBank(name: 'B库', createdAt: now));
    final ids = await db.insertQuestions([
      for (var i = 0; i < 3; i++) question(bankA, 'A题$i'),
    ]);
    await db.updateBankQuestionCount(bankA, 3);
    await db.updateBankQuestionCount(bankB, 0);

    final moved = await db.moveQuestions(ids.take(2).toList(), bankB);

    expect(moved, 2);
    final banks = await db.getAllBanks();
    expect(banks.firstWhere((b) => b.id == bankA).questionCount, 1);
    expect(banks.firstWhere((b) => b.id == bankB).questionCount, 2);
    expect((await db.getQuestionsByBank(bankA)).single.title, 'A题2');
  });

  test('删题：配图/作答记录/错题本/复习卡一并清理，题数重算', () async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final bankId =
        await db.insertBank(QuestionBank(name: '删题库', createdAt: now));
    final img = QuestionImage(
      position: 0,
      width: 2,
      height: 2,
      content: Uint8List.fromList(const [1, 2, 3, 4]),
    );
    final ids = await db.insertQuestions([
      question(bankId, '带图题 {{img:0}}', images: [img]),
      question(bankId, '保留题'),
    ]);
    await db.updateBankQuestionCount(bankId, 2);
    await db.addToErrorBook(ids.first);
    final raw = await db.database;
    await raw.insert('answer_records', {
      'question_id': ids.first,
      'user_answer': 'B',
      'is_correct': 0,
      'answered_at': now,
    });
    await raw.insert('fsrs_cards', {
      'question_id': ids.first,
      'stability': 1.0,
      'difficulty': 5.0,
      'review_count': 1,
      'last_review_at': now,
      'next_review_at': now,
    });

    await db.deleteQuestions([ids.first]);

    expect((await db.getQuestionsByBank(bankId)).single.title, '保留题');
    expect(await db.getImagesForQuestions([ids.first]), isEmpty);
    expect(
        await raw.query('answer_records',
            where: 'question_id = ?', whereArgs: [ids.first]),
        isEmpty);
    expect(
        await raw.query('error_book',
            where: 'question_id = ?', whereArgs: [ids.first]),
        isEmpty);
    expect(
        await raw.query('fsrs_cards',
            where: 'question_id = ?', whereArgs: [ids.first]),
        isEmpty);
    expect((await db.getAllBanks()).single.questionCount, 1);
  });
  test('知识库文档：可重命名、可跨库移动（分块跟随，旧库检索不到）', () async {
    final kb = KbService.instance;
    final db = DatabaseService.instance;
    final kbA = await kb.createKnowledgeBase('内科');
    final kbB = await kb.createKnowledgeBase('外科');
    final file = File('${tmp.path}/讲义.txt');
    file.writeAsStringSync(
        '缺铁性贫血是最常见的贫血类型，多见于育龄期女性。\n' * 40);

    final docId = await kb.importDocument(kbA, file.path);
    await kb.renameDocument(docId, '内科学讲义.md');

    final inA = await kb.listDocuments(kbA);
    expect(inA.single.name, '内科学讲义.md');
    expect(await db.getKbChunks(kbA), isNotEmpty);

    await kb.moveDocument(docId, kbA, kbB);

    expect(await kb.listDocuments(kbA), isEmpty);
    final inB = await kb.listDocuments(kbB);
    expect(inB.single.name, '内科学讲义.md');
    expect(inB.single.kbId, kbB);
    // 分块必须一起搬家，否则旧库还能检索到已搬走的内容
    expect(await db.getKbChunks(kbA), isEmpty);
    expect(await db.getKbChunks(kbB), isNotEmpty);
  });
}
