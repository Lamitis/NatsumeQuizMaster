import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_file_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_service.dart';

/// 知识库 JSON 导出/导入往返（v13）。
///
/// 知识库作为「约束 AI 的资料」必须能随文件往返：导出后导入，
/// 文档与文本块不丢，别人才拿得到同一份知识库。
void main() {
  late Directory tmp;
  const now = '2026-10-27T00:00:00.000';

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_kb_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('知识库导出再导入：文档与文本块往返不丢', () async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance
        .createKnowledgeBase('病理学笔记', description: '测试描述');

    final docId = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '贫血.md',
      source: 'md',
      fileExt: 'md',
      content: '贫血是指血液中红细胞或血红蛋白含量低于正常值。',
      createdAt: now,
    ));
    await db.insertKbChunks([
      KbChunk(
          docId: docId,
          kbId: kbId,
          position: 0,
          text: '贫血是指血液中红细胞或血红蛋白含量低于正常值。',
          createdAt: now),
    ]);

    final dest = '${tmp.path}/kb.json';
    final path = await KbFileService.exportKnowledgeBase(kbId, dest);
    expect(path, isNotNull);
    // v1.41.2：同一份知识库再次导入会按 uid/内容签名跳过；
    // 这里先删原库，验证的仍是「导出 → 导入」的往返完整性。
    await db.deleteKnowledgeBase(kbId);

    // 导入到同一库（知识库 id 会新分配）
    final (importedId, err) = await KbFileService.importKbFile(dest);
    expect(err, isNull);
    expect(importedId, greaterThan(0));
    expect(importedId, isNot(kbId));

    final docs = await db.getKbDocuments(importedId);
    expect(docs, hasLength(1));
    expect(docs.first.name, '贫血.md');
    expect(docs.first.content, contains('贫血'));

    final chunks = await db.getKbChunks(importedId);
    expect(chunks, hasLength(1));
    expect(chunks.first.text, contains('血红蛋白'));
  });

  test('非知识库 JSON（缺 format 标记）拒绝导入', () async {
    final bad = File('${tmp.path}/bad.json')
      ..writeAsStringSync('{"name":"x","documents":[]}');
    final (id, err) = await KbFileService.importKbFile(bad.path);
    expect(id, 0);
    expect(err, contains('format'));
  });

  test('空知识库导出返回 null（没有文档可导）', () async {
    final kbId = await KbService.instance.createKnowledgeBase('空库');
    final path =
        await KbFileService.exportKnowledgeBase(kbId, '${tmp.path}/empty.json');
    expect(path, isNull);
  });

  // ════════════════ v1.42：单文件导出识别 bug 的闭环回归 ════════════════
  //
  // 现象：单个知识库导出时生成的文件认不出类型 / 再次导入失败。
  // 根因有两层：① 调用方直接拿知识库名拼路径，名字带 `/ : * ?` 时写入失败
  // 或没有后缀；② 导出内容缺少统一的识别头。修完后必须能「导出即导入」。

  test('单文件导出强制 .json 后缀，并带标准识别头', () async {
    final db = DatabaseService.instance;
    final kbId = await KbService.instance.createKnowledgeBase('内/外科:笔记');
    await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: 'doc.md',
      content: '休克的本质是有效循环血量不足。',
      createdAt: now,
    ));

    // 故意给一个没有后缀的目标路径
    final path =
        await KbFileService.exportKnowledgeBase(kbId, '${tmp.path}/无后缀导出');
    expect(path, isNotNull);
    expect(path!.toLowerCase().endsWith('.json'), isTrue);

    final raw = File(path).readAsStringSync();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['format'], KbFileService.formatMarker);
    expect(decoded['version'], '1');
    expect(decoded['kind'], 'single');
    expect(decoded['document_count'], 1);
    expect(decoded['documents'], hasLength(1));

    // 闭环：导出文件立刻能被导入 100% 还原
    await db.deleteKnowledgeBase(kbId);
    final (importedId, err) = await KbFileService.importKbFile(path);
    expect(err, isNull);
    expect(importedId, greaterThan(0));
    final docs = await db.getKbDocuments(importedId);
    expect(docs.single.name, 'doc.md');
    expect(docs.single.content, contains('有效循环血量'));
  });

  test('导出文件名：非法字符被替换、后缀强制补齐', () {
    expect(KbFileService.singleExportFileName('内/外科:笔记*?'), '内_外科_笔记__.json');
    expect(KbFileService.singleExportFileName('已经带了.JSON'), '已经带了.JSON');
    expect(KbFileService.singleExportFileName('   '), '知识库.json');
    expect(KbFileService.ensureSingleFileExtension('x'), 'x.json');
    expect(KbFileService.ensureSingleFileExtension('x.JSON'), 'x.JSON');
  });

  test('兼容外层包装：knowledge_base 里再放标准格式也能导入', () async {
    final wrapped = File('${tmp.path}/wrapped.json')
      ..writeAsStringSync(jsonEncode({
        'wrapper': 'natsume-export-v2',
        'knowledge_base': {
          'format': KbFileService.formatMarker,
          'version': '1',
          'name': '包装过的知识库',
          'documents': [
            {'name': 'a.md', 'content': '动作电位是细胞兴奋的标志。'}
          ],
        },
      }));
    final (id, err) = await KbFileService.importKbFile(wrapped.path);
    expect(err, isNull);
    expect(id, greaterThan(0));
    final docs = await DatabaseService.instance.getKbDocuments(id);
    expect(docs.single.name, 'a.md');
  });

  test('分类 / 世界导出包：zip 魔数 + world.json 可被识别', () async {
    final world = {
      'format': 'natsume-world',
      'type': 'category_export',
      'name': '分类导出',
    };
    final bytes = utf8.encode(jsonEncode(world));
    final archive = Archive()
      ..addFile(ArchiveFile('world.json', bytes.length, bytes));
    final path = '${tmp.path}/分类测试.natsume-world.zip';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);

    expect(await KbFileService.isBundleFile(path), isTrue);
    expect(await KbFileService.isWorldFile(path), isTrue);
    // 不会被误当成普通知识库 JSON
    final (id, err) = await KbFileService.importKbFile(path);
    expect(id, 0);
    expect(err, isNotNull);
  });
}
