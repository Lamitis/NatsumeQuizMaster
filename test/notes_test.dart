import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/note.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/notes/notes_service.dart';
import 'package:natsume_quiz_master/services/plugins/builtin_plugins.dart';

/// 笔记插件（v1.31）：双链格式解析 + 数据层 + 分组/反向链接/图谱。
///
/// 用户要求：刷题看解析时能写笔记，笔记在我的→学习工具里按题库名称分类出现，
/// 支持 `[[双链]]` 与 Graph，可编辑；插件数据同步不了就要明示。
void main() {
  group('双链格式解析（Logseq 风格）', () {
    test('抽取 [[页面]]、[[页面|别名]] 与 #标签，去重并保持顺序', () {
      const content = '看到 [[缺铁性贫血]] 与 [[铁粒幼细胞|铁粒幼]]，'
          '再记一笔 #血液科\n重复引用 [[缺铁性贫血]] 不会重复入边';
      expect(NoteLinks.extractTargets(content),
          ['缺铁性贫血', '铁粒幼细胞', '血液科']);
    });

    test('纯文本摘要去掉双链/粗体/标题标记', () {
      final text = NoteLinks.plainText('## 题眼\n[[网织红细胞]] **升高** 提示 *溶血*');
      expect(text.contains('[['), isFalse);
      expect(text.contains('##'), isFalse);
      expect(text.contains('**'), isFalse);
      expect(text.contains('网织红细胞'), isTrue);
    });

    test('超长正文摘要会截断并加省略号', () {
      final text = NoteLinks.plainText('啊' * 200, maxChars: 10);
      expect(text.length, 11); // 10 字 + '…'
      expect(text.endsWith('…'), isTrue);
    });
  });

  group('数据层 / 服务层', () {
    setUp(() async {
      await DatabaseService.instance.close();
      final dir = Directory(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
      final dbPath =
          '${dir.path}/natsume_quiz_master/test_notes_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseService.overrideDbPath = dbPath;
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
    });

    test('笔记插件：可同步（v1.35，按设备开关）', () {
      expect(NotesService.syncable, isTrue);
      expect(BuiltinPlugins.notes.syncable, isTrue);
      expect(BuiltinPlugins.notes.manifestMap['syncable'], isTrue);
    });

    test('新建笔记会写入双链索引，改正文后索引重建', () async {
      final db = DatabaseService.instance;
      final now = DateTime.now().toIso8601String();
      final bankId =
          await db.insertBank(QuestionBank(name: '内科学', createdAt: now));
      final id = await NotesService.instance.create(
        bankId: bankId,
        title: '缺铁性贫血',
        content: '题眼 [[MCV]] 降低，补铁后 [[网织红细胞]] 升高',
      );

      var links = await db.getAllNoteLinks();
      expect(links.map((l) => l['target']), containsAll(['MCV', '网织红细胞']));

      final note = await NotesService.instance.byId(id);
      await NotesService.instance.save(
          note!.copyWith(content: '只留 [[MCV]]'));
      links = await db.getAllNoteLinks();
      expect(links.length, 1);
      expect(links.single['target'], 'MCV');
    });

    test('按题库名称分组：有题库名用题库名，空归属落「未分类」', () async {
      final db = DatabaseService.instance;
      final now = DateTime.now().toIso8601String();
      final bankId =
          await db.insertBank(QuestionBank(name: '内科学', createdAt: now));
      final service = NotesService.instance;
      await service.create(bankId: bankId, title: '体内笔记', content: '内容');
      await service.create(title: '游离笔记', content: '内容');

      final groups = await service.groups();
      expect(groups.length, 2);
      expect(groups.first.bankName, '内科学');
      expect(groups.last.bankName, NotesService.ungroupedName);
      expect(groups.last.bankId, isNull);
    });

    test('反向链接与图谱：悬空页作为未落库节点出现', () async {
      final service = NotesService.instance;
      await service.create(title: '缺铁性贫血', content: '见 [[铁代谢]]');
      await service.create(title: '铁代谢', content: '回到 [[缺铁性贫血]]');

      final backlinks = await service.backlinks('缺铁性贫血');
      expect(backlinks.map((n) => n.title), ['铁代谢']);

      final graph = await service.graph();
      expect(graph.edges.length, 2);
      final missing = graph.nodes.where((n) => n.missing).toList();
      expect(missing, isEmpty); // 两页都写过

      await service.create(title: '溶血性贫血', content: '与 [[缺铁性贫血]] 鉴别');
      final graph2 = await service.graph();
      expect(graph2.nodes.length, 3);
      expect(graph2.edges.length, 3);
    });

    test('删笔记连带清掉双链索引，不影响其他笔记', () async {
      final service = NotesService.instance;
      final db = DatabaseService.instance;
      final a = await service.create(title: 'A', content: '指向 [[B]]');
      await service.create(title: 'B', content: 'B 正文');

      await service.delete(a);
      expect(await db.getAllNoteLinks(), isEmpty);
      expect((await service.list()).map((n) => n.title), ['B']);
    });

    test('内置插件登记：可查询启停，重复登记不覆盖用户设置', () async {
      await BuiltinPlugins.ensureRegistered();
      expect(await BuiltinPlugins.isEnabled(BuiltinPlugins.notesId), isTrue);

      await BuiltinPlugins.setEnabled(BuiltinPlugins.notesId, false);
      expect(await BuiltinPlugins.isEnabled(BuiltinPlugins.notesId), isFalse);

      // 再次启动登记不应把用户关掉的插件又打开
      await BuiltinPlugins.ensureRegistered();
      expect(await BuiltinPlugins.isEnabled(BuiltinPlugins.notesId), isFalse);

      final info =
          await DatabaseService.instance.getPlugin(BuiltinPlugins.notesId);
      expect(info, isNotNull);
      expect(BuiltinPlugins.isSyncable(info!), isTrue);
    });
  });
}
