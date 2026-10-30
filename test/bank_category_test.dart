import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/bank_manage_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// 题库分类树（schema v15）。
///
/// 需求是「多个题库可以分类进一棵用户自建的分类树」。这里锁定四件事：
/// ① 父子关系与排序落库正确；② 删分类时子分类/题库**上移一级**而不是连带
/// 删除；③ 移动分类不许成环（树成环会让渲染无限递归）；④ 老库升 v15 时
/// 自动补表补列，既有题库保持「未分类」。
void main() {
  late Directory tmp;
  const now = '2026-10-29T00:00:00.000';

  setUp(() async {
    await DatabaseService.instance.close();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('natsume_cat_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<int> seedBank(String name, {int? categoryId}) =>
      DatabaseService.instance.insertBank(
          QuestionBank(name: name, createdAt: now, categoryId: categoryId));

  test('分类树：父子关系、同级排序、改名', () async {
    final db = DatabaseService.instance;
    final root = await db.insertBankCategory(name: '内科学');
    final child = await db.insertBankCategory(name: '心血管', parentId: root);
    await db.insertBankCategory(name: '心衰', parentId: child);

    var all = await db.getAllBankCategories();
    expect(all.map((c) => c.name), ['内科学', '心血管', '心衰']);
    expect(all.firstWhere((c) => c.id == child).parentId, root);

    // 同级追加：sort_order 递增，新分类排在后面
    await db.insertBankCategory(name: '呼吸科', parentId: root);
    all = await db.getAllBankCategories();
    expect(all.map((c) => c.name), ['内科学', '心血管', '心衰', '呼吸科']);

    await db.renameBankCategory(child, '心脏');
    all = await db.getAllBankCategories();
    expect(all.firstWhere((c) => c.id == child).name, '心脏');
  });

  test('题库挂到分类下；删分类时子分类与题库上移一级（不删题库）', () async {
    final db = DatabaseService.instance;
    final root = await db.insertBankCategory(name: '根');
    final mid = await db.insertBankCategory(name: '中', parentId: root);
    final leaf = await db.insertBankCategory(name: '叶', parentId: mid);
    final bankId = await seedBank('挂在中间的题库', categoryId: mid);

    await db.deleteBankCategory(mid);

    final cats = await db.getAllBankCategories();
    expect(cats.map((c) => c.id), isNot(contains(mid)));
    expect(cats.firstWhere((c) => c.id == leaf).parentId, root);

    final banks = await db.getAllBanks();
    expect(banks.single.id, bankId, reason: '删分类不能连带删题库');
    expect(banks.single.categoryId, root, reason: '题库上移一级');
  });

  test('移动分类：挪到根/别处可以，成环被拒', () async {
    final db = DatabaseService.instance;
    final a = await db.insertBankCategory(name: 'A');
    final b = await db.insertBankCategory(name: 'B', parentId: a);
    final c = await db.insertBankCategory(name: 'C', parentId: b);

    expect(await db.moveBankCategory(a, c), isFalse, reason: '挂到自己孙子下会成环');
    expect(await db.moveBankCategory(a, a), isFalse, reason: '挂到自己下会成环');

    expect(await db.moveBankCategory(c, null), isTrue);
    expect(
        (await db.getAllBankCategories()).firstWhere((x) => x.id == c).parentId,
        isNull);
    expect(await db.moveBankCategory(c, a), isTrue);
    expect(
        (await db.getAllBankCategories()).firstWhere((x) => x.id == c).parentId,
        a);
  });
  test('AppState：整支口径取题库 / 未分类列表', () async {
    final state = AppState();
    final root = await state.createBankCategory('内科');
    final child = await state.createBankCategory('心血管', parentId: root);
    final rootBank = await seedBank('根题库', categoryId: root);
    final childBank = await seedBank('子题库', categoryId: child);
    final loose = await seedBank('散题库');
    await state.refreshBanks();

    expect(state.categoryWithDescendants(root), {root, child});
    expect(state.bankIdsInCategory(root), {rootBank, childBank});
    expect(state.bankIdsInCategory(child), {childBank});
    expect(state.uncategorizedBanks.map((b) => b.id), [loose]);

    // 改名/删分类都会刷新列表，界面不再需要手动 reload
    await state.renameBankCategory(child, '心脏');
    expect(state.categories.firstWhere((c) => c.id == child).name, '心脏');

    await state.deleteBankCategory(child);
    expect(state.categoryWithDescendants(root), {root});
    expect(state.categories.map((c) => c.id), [root]);
  });

  test('v14 库升到 v15：自动补分类表与 category_id 列，既有题库保持未分类', () async {
    final path = '${tmp.path}/flashcard.db';
    // 手工造一个 v14 结构的库（question_banks 没有 category_id、没有分类表）
    final legacy = await databaseFactory.openDatabase(path);
    await legacy.execute('''
      CREATE TABLE question_banks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        file_source TEXT,
        question_count INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        uid TEXT,
        updated_at TEXT
      )
    ''');
    await legacy.insert('question_banks', {
      'name': '旧题库',
      'question_count': 3,
      'created_at': now,
      'uid': 'uid-legacy',
      'updated_at': now,
    });
    await legacy.execute('PRAGMA user_version = 14');
    await legacy.close();

    final db = DatabaseService.instance;
    final banks = await db.getAllBanks();
    expect(banks.single.name, '旧题库');
    expect(banks.single.categoryId, isNull, reason: '老题库默认未分类');

    final raw = await db.database;
    final cols = (await raw.rawQuery('PRAGMA table_info(question_banks)'))
        .map((r) => r['name'])
        .toList();
    expect(cols, contains('category_id'));
    final tables = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='bank_categories'");
    expect(tables, hasLength(1));

    final catId = await db.insertBankCategory(name: '升级后新建的分类');
    await db.setBankCategory(banks.single.id!, catId);
    expect((await db.getAllBanks()).single.categoryId, catId);
  });

  testWidgets('题库管理页按分类树渲染，收起父分类时子项一起隐藏', (tester) async {
    // 真实 DB I/O 不能在 fake-async 里 await（会一直挂着），用 runAsync 建数据
    late AppState state;
    await tester.runAsync(() async {
      state = AppState();
      final root = await state.createBankCategory('内科');
      final child = await state.createBankCategory('心血管', parentId: root);
      await seedBank('心衰题库', categoryId: child);
      await state.refreshBanks();
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: BankManageScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('内科'), findsOneWidget);
    expect(find.text('心血管'), findsOneWidget);
    expect(find.text('心衰题库'), findsOneWidget);

    // 点分类行 = 收起整支
    await tester.tap(find.text('内科'));
    await tester.pumpAndSettle();
    expect(find.text('心血管'), findsNothing);
    expect(find.text('心衰题库'), findsNothing);

    // 再点一次展开
    await tester.tap(find.text('内科'));
    await tester.pumpAndSettle();
    expect(find.text('心血管'), findsOneWidget);
  });
}
