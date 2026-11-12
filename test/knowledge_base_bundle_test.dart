import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_file_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';

/// 多知识库包（`.natsume-kb`）导出 / 导入（v1.41.4）。
///
/// 用户要的是「像导出题库那样自由勾选几个知识库，打成一个包带走」，
/// 并且这个包能被现有的「导入知识库」一次性还原——所以这里既验证
/// 打包/解包往返，也验证重复导入不会把知识库翻倍。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_kb_bundle_');
    DatabaseService.overrideDbPath = '${tmp.path}/bundle.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<int> seedKb(String name, String content) async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance.createKnowledgeBase(name);
    final now = DateTime.now().toIso8601String();
    final docId = await db.insertKbDocument(KbDocument(
        kbId: kbId, name: '$name.md', content: content, createdAt: now));
    await db.insertKbChunks([
      KbChunk(
          docId: docId,
          kbId: kbId,
          position: 0,
          text: content,
          createdAt: now),
    ]);
    return kbId;
  }

  test('勾选两个知识库 → 一个包 → 「导入知识库」一次性还原', () async {
    final db = DatabaseService.instance;
    final a = await seedKb('病理笔记', '炎症的核心是血管反应。');
    final b = await seedKb('药理笔记', '阿司匹林不可逆抑制 COX-1。');

    final dest = '${tmp.path}/知识库合集.natsume-kb';
    final exported =
        await KbFileService.exportBundle(kbIds: [a, b], destPath: dest);
    expect(exported.saved, isTrue);
    expect(exported.kbCount, 2);
    expect(exported.skippedCount, 0);
    expect(await KbFileService.isBundleFile(dest), isTrue,
        reason: '导入页要靠它判断「这是包不是单文件」');

    // 清空本机（模拟另一台设备 / 另一次安装）
    await db.deleteKnowledgeBase(a);
    await db.deleteKnowledgeBase(b);
    expect(await db.getAllKnowledgeBases(), isEmpty);

    final imported = await KbFileService.importBundle(dest);
    expect(imported.error, isNull);
    expect(imported.kbCount, 2);
    expect(imported.skippedCount, 0);

    final bases = await db.getAllKnowledgeBases();
    expect(bases.map((e) => e.name).toSet(), {'病理笔记', '药理笔记'});
    final target = bases.firstWhere((e) => e.name == '病理笔记');
    final docs = await db.getKbDocuments(target.id!);
    expect(docs, hasLength(1));
    expect(docs.single.content, contains('血管反应'));
    expect(await db.getKbChunks(target.id!), isNotEmpty,
        reason: '切块要一起还原，否则 AI 检索不到');
  });

  test('同一个包导入两次：第二次全部跳过，知识库不翻倍', () async {
    final db = DatabaseService.instance;
    final a = await seedKb('生理笔记', '静息电位主要由钾离子通透性决定。');
    final dest = '${tmp.path}/单个.natsume-kb';
    final exported =
        await KbFileService.exportBundle(kbIds: [a], destPath: dest);
    expect(exported.kbCount, 1);

    // 删掉原库，让第一次导入真的能建库
    await db.deleteKnowledgeBase(a);
    final first = await KbFileService.importBundle(dest);
    expect(first.kbCount, 1);
    expect(await db.getAllKnowledgeBases(), hasLength(1));

    final second = await KbFileService.importBundle(dest);
    expect(second.kbCount, 0);
    expect(second.skippedCount, 1);
    expect(await db.getAllKnowledgeBases(), hasLength(1));
  });

  test('没有文档的知识库被跳过；全都没文档时不产出包', () async {
    final empty = await KbService.instance.createKnowledgeBase('空库');
    final dest = '${tmp.path}/空.natsume-kb';
    final result =
        await KbFileService.exportBundle(kbIds: [empty], destPath: dest);
    expect(result.saved, isFalse);
    expect(result.skippedCount, 1);
    expect(File(dest).existsSync(), isFalse);
  });

  test('不是知识库包的文件：报可读错误而不是抛异常', () async {
    final bogus = File('${tmp.path}/bogus.natsume-kb')
      ..writeAsStringSync('not a zip');
    final result = await KbFileService.importBundle(bogus.path);
    expect(result.kbCount, 0);
    expect(result.error, isNotNull);
  });
}
