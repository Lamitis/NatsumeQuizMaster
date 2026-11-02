import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/models/knowledge_base.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/bank_manage_screen.dart';
import 'package:natsume_quiz_master/screens/knowledge_base_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// 题库 / 知识库批量操作（v1.39.3）：
/// ① 批量删除走事务、只删选中的；② 批量移动只改分类；③ 两页都能长按进多选。
void main() {
  late Directory tmp;
  const now = '2026-11-01T00:00:00.000';

  setUp(() async {
    await DatabaseService.instance.close();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('natsume_batch_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<int> seedBank(String name, {int questions = 2}) async {
    final db = DatabaseService.instance;
    final id = await db.insertBank(QuestionBank(name: name, createdAt: now));
    if (questions > 0) {
      await db.insertQuestions([
        for (var i = 0; i < questions; i++)
          Question(
            bankId: id,
            title: '$name-题$i',
            options: const ['A', 'B'],
            correctAnswer: 'A',
            createdAt: now,
          ),
      ]);
      await db.updateBankQuestionCount(id, questions);
    }
    return id;
  }

  Future<int> seedKb(String name) async {
    final db = DatabaseService.instance;
    final kbId = await db.insertKnowledgeBase(
      KnowledgeBase(name: name, createdAt: now),
    );
    final docId = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '$name-文档',
      content: '资料正文',
      createdAt: now,
    ));
    await db.insertKbChunks([
      KbChunk(
        docId: docId,
        kbId: kbId,
        position: 0,
        text: '资料正文',
        createdAt: now,
      ),
    ]);
    return kbId;
  }

  test('deleteBanks：只删选中题库，连带题目；未选中的保持完整', () async {
    final db = DatabaseService.instance;
    final keep = await seedBank('保留题库');
    final drop1 = await seedBank('删除题库一');
    final drop2 = await seedBank('删除题库二');

    await db.deleteBanks([drop1, drop2, drop1]);

    final banks = await db.getAllBanks();
    expect(banks.map((b) => b.id), [keep]);
    expect((await db.getQuestionsByBank(drop1)), isEmpty);
    expect((await db.getQuestionsByBank(drop2)), isEmpty);
    expect((await db.getQuestionsByBank(keep)), hasLength(2));
  });

  test('moveBanksToCategory：批量挂分类，也可批量回到未分类', () async {
    final db = DatabaseService.instance;
    final cat = await db.insertBankCategory(name: '病理学');
    final b1 = await seedBank('题库一');
    final b2 = await seedBank('题库二');
    final b3 = await seedBank('题库三');

    await db.moveBanksToCategory([b1, b2], cat);
    var banks = await db.getAllBanks();
    expect(banks.firstWhere((b) => b.id == b1).categoryId, cat);
    expect(banks.firstWhere((b) => b.id == b2).categoryId, cat);
    expect(banks.firstWhere((b) => b.id == b3).categoryId, isNull);

    await db.moveBanksToCategory([b1], null);
    banks = await db.getAllBanks();
    expect(banks.firstWhere((b) => b.id == b1).categoryId, isNull);
    expect(banks.firstWhere((b) => b.id == b2).categoryId, cat);
  });

  test('AppState.deleteBanks：同时清掉刷题勾选并刷新列表', () async {
    final state = AppState();
    await state.init();
    final a = await seedBank('A');
    final b = await seedBank('B');
    await state.refreshBanks();
    state.toggleBankSelection(a);

    await state.deleteBanks([a]);

    expect(state.banks.map((x) => x.id), [b]);
    expect(state.selectedBankIds, isNot(contains(a)));
  });

  test('deleteKnowledgeBases：chunks → documents → bases 一并清理，未选中的保留', () async {
    final db = DatabaseService.instance;
    final keep = await seedKb('保留库');
    final drop1 = await seedKb('删除库一');
    final drop2 = await seedKb('删除库二');

    await db.deleteKnowledgeBases([drop1, drop2]);

    expect((await db.getAllKnowledgeBases()).map((k) => k.id), [keep]);
    expect(await db.getKbDocuments(drop1), isEmpty);
    expect(await db.getKbDocuments(drop2), isEmpty);
    final chunks = await db.getKbChunks(drop1);
    expect(chunks, isEmpty);
    expect(await db.getKbDocuments(keep), hasLength(1));
  });

  testWidgets('题库管理：长按进入多选，全选 / 取消恢复普通列表', (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = AppState();
      await state.init();
      await seedBank('题库A');
      await seedBank('题库B');
      await state.refreshBanks();
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: BankManageScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('题库A'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('题库管理'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('知识库：长按进入多选，全选 / 取消恢复普通列表', (tester) async {
    await tester.runAsync(() async {
      await seedKb('知识库A');
      await seedKb('知识库B');
    });
    await tester.pumpWidget(const MaterialApp(home: KnowledgeBaseScreen()));

    // _reload 是真实 DB 异步：给 fake-async 之外的 microtask 一点时间
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('知识库A').evaluate().isNotEmpty) break;
    }
    expect(find.text('知识库A'), findsOneWidget);

    await tester.longPress(find.text('知识库A'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('知识库'), findsWidgets);
    expect(find.byType(Checkbox), findsNothing);
  });
}
