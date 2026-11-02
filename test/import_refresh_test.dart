import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/bank_manage_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/plugins/world_service.dart';

/// 导入后的全局刷新回归（v1.39.4）。
///
/// 世界 / 分类包导入只写数据库，UI 不会自己知道。这里模拟真实导入流程：
/// 先导出一个分类包、清掉源数据、再导入，随后调用
/// `AppState.refreshAllDataAfterImport()`，断言题库管理页立刻渲染新题库，
/// 不需要重启应用。
void main() {
  late Directory tmp;
  const now = '2026-11-01T00:00:00.000';

  setUp(() async {
    await DatabaseService.instance.close();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('natsume_import_refresh_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('分类包导入后刷新 AppState，题库名称立刻出现在题库管理列表', (tester) async {
    late AppState state;
    late String packagePath;
    late int importedBankId;

    await tester.runAsync(() async {
      final db = DatabaseService.instance;
      state = AppState();

      await db.insertBank(QuestionBank(name: '已有题库', createdAt: now));
      final categoryId = await db.insertBankCategory(name: '病理学');
      importedBankId = await db.insertBank(QuestionBank(
        name: '导入后的新题库',
        createdAt: now,
        categoryId: categoryId,
      ));
      await db.insertQuestions([
        Question(
          bankId: importedBankId,
          title: '炎症的核心表现是什么？',
          options: const ['A', 'B'],
          correctAnswer: 'A',
          createdAt: now,
        ),
      ]);
      await db.updateBankQuestionCount(importedBankId, 1);
      await state.refreshBanks();

      // 先导出一个分类包，再从当前库删掉它——模拟「换设备后导入」
      packagePath = (await WorldService.exportCategory(
        categoryId: categoryId,
        destPath: '${tmp.path}/category.natsume-world.zip',
        includeKbs: false,
      ))!;
      await db.deleteBank(importedBankId);
      await db.deleteBankCategory(categoryId);
      await state.refreshBanks();
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: BankManageScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('已有题库'), findsOneWidget);
    expect(find.text('导入后的新题库'), findsNothing, reason: '导入前不应出现包里的题库');

    final result = await tester.runAsync(() async {
      final r = await WorldService.importWorld(packagePath);
      // WorldOverviewScreen 导入成功后的同一条刷新路径
      await state.refreshAllDataAfterImport();
      return r;
    });
    expect(result!.bankCount, 1);

    await tester.pumpAndSettle();

    expect(find.text('病理学'), findsOneWidget, reason: '分类树的根节点也应随刷新出现');
    expect(find.text('导入后的新题库'), findsOneWidget,
        reason: '刷新后必须立刻显示新导入的题库，不能要求用户重启');
  });
}
