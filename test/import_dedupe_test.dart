import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/models/knowledge_base.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/bank_file_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_file_service.dart';
import 'package:natsume_quiz_master/services/plugins/world_service.dart';

/// 重复导入去重（v1.41.2）。
///
/// 覆盖「应用更新后题库/知识库重复出现一份」的根因：
/// 导入链路只按名字改名、从不检查 uid / 内容，导致同一份文件（或同一个
/// 世界包）再导入一次就多一份数据。现在的契约：
/// 1. 带 uid 的文件 → uid 命中直接跳过；
/// 2. 老文件没有 uid → 同名且内容签名一致 → 跳过；
/// 3. 同名但内容不同 → 仍按老逻辑改名导入（这是两份不同资料）；
/// 4. 世界包重复导入 → 成员被跳过，库里数量不增长。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_import_dedupe_');
    DatabaseService.overrideDbPath = '${tmp.path}/dedupe.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<int> seedBank({String name = '重复题库', String? uid}) async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final id = await db
        .insertBank(QuestionBank(name: name, uid: uid, createdAt: now));
    await db.insertQuestions([
      Question(
          bankId: id,
          title: '$name-题',
          options: const ['A', 'B'],
          correctAnswer: 'A',
          createdAt: now),
    ]);
    await db.updateBankQuestionCount(id, 1);
    return id;
  }

  Future<int> seedKb({String name = '重复知识库', String? uid}) async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    final kbId = await db.insertKnowledgeBase(
        KnowledgeBase(name: name, uid: uid, createdAt: now));
    final docId = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '文档.md',
      content: '这是知识库正文，用于内容签名去重。',
      createdAt: now,
    ));
    await db.insertKbChunks([
      KbChunk(
          docId: docId,
          kbId: kbId,
          position: 0,
          text: '这是知识库正文，用于内容签名去重。',
          createdAt: now),
    ]);
    return kbId;
  }

  group('题库导入', () {
    test('老格式（无 uid）重复导入：第二次跳过，不生成 X(2)', () async {
      final db = DatabaseService.instance;
      final path = '${tmp.path}/legacy.json';
      await File(path).writeAsString(
          '{"format":"natsume-quiz-questions","name":"临床检验","count":1,'
          '"questions":[{"title":"q1","correct_answer":"A"}]}');

      final first = await BankFileService.importBankFile(path);
      expect(first.bankCount, 1);
      expect(first.skippedCount, 0);

      final second = await BankFileService.importBankFile(path);
      expect(second.bankCount, 0, reason: '重复导入不应再建题库');
      expect(second.questionCount, 0);
      expect(second.skippedCount, 1);

      final banks = await db.getAllBanks();
      expect(banks.where((b) => b.name.startsWith('临床检验')).length, 1);
    });

    test('带 uid 的导出文件：再导入按 uid 跳过', () async {
      final db = DatabaseService.instance;
      final bankId = await seedBank(name: '带UID题库', uid: 'bank-uid-1');
      final dest = '${tmp.path}/bank_uid.json';
      final exported = await BankFileService.exportBank(bankId, '带UID题库', dest);
      expect(exported, isNotNull);
      expect(
          await File(exported!).readAsString(), contains('"uid": "bank-uid-1"'));

      final before = (await db.getAllBanks()).length;
      final again = await BankFileService.importBankFile(exported);
      expect(again.bankCount, 0);
      expect(again.skippedCount, 1);
      expect((await db.getAllBanks()).length, before);
    });

    test('同名不同内容仍改名导入（两份不同题库）', () async {
      final db = DatabaseService.instance;
      await seedBank(name: '同名题库');
      final path = '${tmp.path}/different.json';
      await File(path).writeAsString(
          '{"format":"natsume-quiz-questions","name":"同名题库","count":1,'
          '"questions":[{"title":"完全不同的题","correct_answer":"B"}]}');

      final r = await BankFileService.importBankFile(path);
      expect(r.bankCount, 1);
      expect(r.renamedCount, 1);
      expect(r.skippedCount, 0);
      final names = (await db.getAllBanks()).map((b) => b.name).toSet();
      expect(names, containsAll({'同名题库', '同名题库(2)'}));
    });

    test('上一份被自动改名成 X(2) 后再导入同一文件：仍按内容跳过（v1.41.4）',
        () async {
      final db = DatabaseService.instance;
      // 本机先有一份同名但内容不同的题库 → 下面这份会被改名成「同名题库(2)」
      await seedBank(name: '同名题库');
      final path = '${tmp.path}/renamed_copy.json';
      await File(path).writeAsString(
          '{"format":"natsume-quiz-questions","name":"同名题库","count":1,'
          '"questions":[{"title":"另一份资料","correct_answer":"B"}]}');

      final first = await BankFileService.importBankFile(path);
      expect(first.bankCount, 1);
      expect(first.renamedCount, 1);

      // 再导一次：内容命中的是改名后的「同名题库(2)」。
      // 以前只比「同名 + 带名字的签名」，于是会再建一份「同名题库(3)」。
      final second = await BankFileService.importBankFile(path);
      expect(second.bankCount, 0, reason: '改名过的旧副本也要按内容认出来');
      expect(second.skippedCount, 1);

      final names = (await db.getAllBanks()).map((b) => b.name).toList();
      expect(names.where((n) => n.startsWith('同名题库')).length, 2,
          reason: '同族题库只应有两份：原题库 + 内容不同的那一份');
    });
  });

  group('预览确认入库', () {
    test('同一份预览内容重复确认：第二次跳过，不生成 X(2)', () async {
      final db = DatabaseService.instance;
      final appState = AppState();
      final question = Question(
        bankId: 0,
        title: '预览题：正常成人安静状态下的心率调节方式是？',
        options: const ['体液调节', '神经调节'],
        correctAnswer: 'B',
        createdAt: DateTime.now().toIso8601String(),
      );

      appState.setPreviewQuestionsForTest([question], bankName: '预览题库');
      await appState.confirmImport();
      expect(await db.getAllBanks(), hasLength(1));

      // 同一份内容再确认一次（连点/重试/覆盖安装后又导一遍）
      appState.setPreviewQuestionsForTest([question], bankName: '预览题库');
      await appState.confirmImport();

      final banks = await db.getAllBanks();
      expect(banks, hasLength(1), reason: '内容相同不应再建一份');
      expect(banks.single.name, '预览题库');
      expect(appState.importStatus, contains('跳过'));
    });
  });

  group('知识库导入', () {
    test('老格式（无 uid）重复导入：第二次跳过', () async {
      final db = DatabaseService.instance;
      final kbId = await seedKb(name: '病理资料');
      final dest = '${tmp.path}/kb_legacy.json';
      expect(await KbFileService.exportKnowledgeBase(kbId, dest), isNotNull);
      // 导出文件没有 uid（原库 uid 为空），先删原库验证首次可导入
      await db.deleteKnowledgeBase(kbId);
      final (importedId, err) = await KbFileService.importKbFile(dest);
      expect(err, isNull);
      expect(importedId, greaterThan(0));

      final (againId, againErr) = await KbFileService.importKbFile(dest);
      expect(againId, 0);
      expect(againErr, contains('已跳过'));
      expect(await db.getAllKnowledgeBases(), hasLength(1));
    });

    test('带 uid 的导出文件：再导入按 uid 跳过', () async {
      final db = DatabaseService.instance;
      final kbId = await seedKb(name: '带UID知识库', uid: 'kb-uid-1');
      final dest = '${tmp.path}/kb_uid.json';
      final exported = await KbFileService.exportKnowledgeBase(kbId, dest);
      expect(exported, isNotNull);
      expect(await File(exported!).readAsString(), contains('"uid": "kb-uid-1"'));

      final (id, err) = await KbFileService.importKbFile(exported);
      expect(id, 0);
      expect(err, contains('已跳过'));
      expect(await db.getAllKnowledgeBases(), hasLength(1));
    });
  });

  group('世界包重复导入', () {
    test('同一个世界包导入两次：题库/知识库数量不增长', () async {
      final db = DatabaseService.instance;
      final bankId = await seedBank(name: '世界题库');
      final kbId = await seedKb(name: '世界知识库');

      final dest = '${tmp.path}/world.natsume-world.zip';
      final path = await WorldService.exportWorld(
        worldId: 'w-dedupe',
        worldName: '去重世界',
        kbIds: [kbId],
        bankIds: [bankId],
        pluginIds: const [],
        destPath: dest,
      );
      expect(path, isNotNull);

      final first = await WorldService.importWorld(dest);
      expect(first.bankCount, 0, reason: '成员已存在：第一次就应跳过');
      expect(first.kbCount, 0);
      expect(first.skippedCount, greaterThanOrEqualTo(2));

      final second = await WorldService.importWorld(dest);
      expect(second.bankCount, 0);
      expect(second.kbCount, 0);
      expect(second.skippedCount, greaterThanOrEqualTo(2));

      expect(await db.getAllBanks(), hasLength(1));
      expect(await db.getAllKnowledgeBases(), hasLength(1));
      expect(await db.getAllWorlds(), hasLength(1));
    });
  });
}
