import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/models/kb_document.dart';
import 'package:natsume_quiz_master/models/knowledge_base.dart';
import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/plugins/world_service.dart';

/// 世界打包/解包往返（v13 · world-overview）。
///
/// 「世界」= 知识库 + 题库 + 插件。导出成单一 zip，导入后三类成员都应回来，
/// 并登记一条 WorldInfo。
void main() {
  late Directory tmp;
  const now = '2026-10-27T00:00:00.000';

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_world_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('世界导出再导入：知识库/题库/插件都回来', () async {
    final db = DatabaseService.instance;

    // 知识库 + 文档 + 块
    final kbId = await db.insertKnowledgeBase(
        KnowledgeBase(name: '病理', createdAt: now));
    final docId = await db.insertKbDocument(KbDocument(
      kbId: kbId,
      name: '贫血.md',
      content: '贫血指红细胞或血红蛋白低于正常。',
      createdAt: now,
    ));
    await db.insertKbChunks([
      KbChunk(
          docId: docId,
          kbId: kbId,
          position: 0,
          text: '贫血指红细胞或血红蛋白低于正常。',
          createdAt: now),
    ]);

    // 题库 + 题
    final bankId = await db.insertBank(QuestionBank(name: '题库A', createdAt: now));
    await db.insertQuestions([
      Question(
          bankId: bankId,
          title: '题干',
          correctAnswer: 'A',
          createdAt: now),
    ]);

    // 插件
    await db.upsertPlugin(PluginInfo(
      id: 'com.test.p',
      name: '测试插件',
      version: '1',
      manifest: jsonEncode({
        'id': 'com.test.p',
        'name': '测试插件',
        'version': '1',
        'capabilities': <String>[],
      }),
      installedAt: now,
    ));

    final dest = '${tmp.path}/world.natsume-world.zip';
    final path = await WorldService.exportWorld(
      worldId: 'w1',
      worldName: '测试世界',
      kbIds: [kbId],
      bankIds: [bankId],
      pluginIds: ['com.test.p'],
      destPath: dest,
    );
    expect(path, isNotNull);

    // 导入前清空，验证能被还原
    await db.deleteKnowledgeBase(kbId);
    await db.deleteBank(bankId);
    await db.deletePlugin('com.test.p');

    final result = await WorldService.importWorld(dest);
    expect(result.kbCount, 1);
    expect(result.bankCount, 1);
    expect(result.pluginCount, 1);
    expect(result.world.name, '测试世界');

    final worlds = await db.getAllWorlds();
    expect(worlds, hasLength(1));
    expect(worlds.first.id, 'w1');
  });

  test('缺 world.json 的世界包拒绝导入', () async {
    final bad = File('${tmp.path}/bad.zip');
    bad.writeAsBytesSync([1, 2, 3]); // 非 zip
    expect(() => WorldService.importWorld(bad.path), throwsA(anything));
  });
}
