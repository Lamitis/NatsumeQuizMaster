import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/plugin_sync_scope.dart';
import 'package:natsume_quiz_master/models/schedule_item.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/notes/notes_service.dart';
import 'package:natsume_quiz_master/services/sync/sync_repository.dart';

/// 插件内容同步（v1.35）：范围模型 + 快照里到底带了什么。
///
/// 用户要求：笔记 / 助教 / 待办至少能同步到手机端，并且**每台设备自己决定**
/// 要不要同步插件内容。这里只验「开关怎么落盘、快照怎么变」，
/// 真正的跨设备合并规则在 `lan_sync_test.dart` 的既定口径上扩展。
void main() {
  group('同步范围模型', () {
    test('默认三项全开', () {
      const scope = PluginSyncScope.all;
      expect(scope.notes, isTrue);
      expect(scope.companion, isTrue);
      expect(scope.schedule, isTrue);
      expect(scope.anyEnabled, isTrue);
      expect(scope.enabledFor(PluginSyncScope.notesPluginId), isTrue);
      expect(scope.enabledFor('natsume.unknown'), isFalse);
    });

    test('encode / decode 往返，坏数据回落全开', () {
      const scope =
          PluginSyncScope(notes: false, companion: true, schedule: false);
      final back = PluginSyncScope.decode(scope.encode());
      expect(back.notes, isFalse);
      expect(back.companion, isTrue);
      expect(back.schedule, isFalse);

      for (final raw in [null, '', 'not json', '[]', '{}']) {
        final fallback = PluginSyncScope.decode(raw);
        expect(fallback.notes, isTrue, reason: 'raw=$raw');
        expect(fallback.companion, isTrue, reason: 'raw=$raw');
        expect(fallback.schedule, isTrue, reason: 'raw=$raw');
      }
    });

    test('withPlugin 只改一项', () {
      final next = PluginSyncScope.all
          .withPlugin(PluginSyncScope.schedulePluginId, false);
      expect(next.schedule, isFalse);
      expect(next.notes, isTrue);
      expect(next.companion, isTrue);
    });
  });

  group('快照导出（真实库）', () {
    setUp(() async {
      await DatabaseService.instance.close();
      final dir = Directory(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
      final dbPath = '${dir.path}/natsume_quiz_master/'
          'test_plugin_sync_${DateTime.now().millisecondsSinceEpoch}.db';
      DatabaseService.overrideDbPath = dbPath;
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
    });

    test('默认导出笔记 / 助教 / 待办三个块', () async {
      final db = DatabaseService.instance;
      await db.setSetting(
          PluginSyncScope.settingsKey, const PluginSyncScope().encode());

      final snapshot = await SyncRepository().exportSnapshot();
      final plugins = snapshot['plugins'] as Map;
      expect(plugins.keys.toSet(), {'notes', 'companion', 'schedule'});
      // 助教块：只带人设与记忆两个字段，不含 api key / endpoint
      final companion = plugins['companion'] as Map;
      expect(companion.keys.toSet(), {'settings', 'memory'});
    });

    test('关掉某一项后快照里不再有它（其余仍带）', () async {
      final db = DatabaseService.instance;
      await db.setSetting(
        PluginSyncScope.settingsKey,
        const PluginSyncScope(notes: false).encode(),
      );

      final snapshot = await SyncRepository().exportSnapshot();
      final plugins = snapshot['plugins'] as Map;
      expect(plugins.containsKey('notes'), isFalse);
      expect(plugins.containsKey('companion'), isTrue);
      expect(plugins.containsKey('schedule'), isTrue);
    });

    test('只同步题库模式一律不带插件内容（分享题库不该带私人笔记）', () async {
      await NotesService.instance.create(
        title: '内科学笔记',
        content: '看到 [[缺铁性贫血]]',
      );
      final snapshot = await SyncRepository().exportSnapshot(banksOnly: true);
      expect(snapshot['plugins'], isEmpty);
    });

    test('笔记与待办写入时自动补 uid，且出现在快照里', () async {
      final db = DatabaseService.instance;
      // 走 NotesService：它会在写完正文后重建双链索引（出链要一起同步）
      await NotesService.instance.create(
        title: '缺铁性贫血',
        content: '[[网织红细胞]] 升高',
      );
      await db.insertScheduleItem(ScheduleItem(
        title: '复习内科',
        detail: '错题 12 道',
        createdAt: '2026-10-30T00:00:00Z',
        updatedAt: '2026-10-30T00:00:00Z',
      ));

      final snapshot = await SyncRepository().exportSnapshot();
      final plugins = snapshot['plugins'] as Map;

      final notesBlock = plugins['notes'] as Map;
      final noteRows = notesBlock['notes'] as List;
      expect(noteRows.length, 1);
      final noteUid = (noteRows.first as Map)['uid'] as String;
      expect(noteUid, isNotEmpty);
      // 双链随笔记一起走
      final links = notesBlock['links'] as List;
      expect(links.length, 1);
      expect((links.first as Map)['note_uid'], noteUid);

      final scheduleBlock = plugins['schedule'] as Map;
      final items = scheduleBlock['items'] as List;
      expect(items.length, 1);
      expect(((items.first as Map)['uid'] as String), isNotEmpty);

      // 本机读回时 uid 也带上（按 uid 合并的前提）
      final stored = await db.getNotes();
      expect(stored.single.uid, noteUid);
      expect(stored.single.originDevice, isNotNull);
    });

    test('待办勾选后快照里是 done=1（完成状态要能带过去）', () async {
      final db = DatabaseService.instance;
      final id = await db.insertScheduleItem(ScheduleItem(
        title: '完成一套真题',
        createdAt: '2026-10-30T00:00:00Z',
        updatedAt: '2026-10-30T00:00:00Z',
      ));
      final item = (await db.getScheduleItem(id))!;
      await db.updateScheduleItem(item.copyWith(
        done: true,
        updatedAt: '2026-10-30T01:00:00Z',
      ));

      final snapshot = await SyncRepository().exportSnapshot();
      final items =
          ((snapshot['plugins'] as Map)['schedule'] as Map)['items'] as List;
      expect(((items.single as Map)['done']), 1);
    });
  });
}
