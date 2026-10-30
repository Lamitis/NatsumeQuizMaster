import 'dart:io';

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
    final kbId = await KbService.instance.createKnowledgeBase('病理学笔记',
        description: '测试描述');

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
}
