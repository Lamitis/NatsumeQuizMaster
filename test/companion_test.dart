import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/companion.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/companion/companion_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/plugins/builtin_plugins.dart';

/// 陪伴插件（v1.32 · 小鲸助教）的数据层与话术契约。
///
/// 守住三件事：
/// ① 场景判定只用真实统计，条理可预期（不达标不该被夸「今天很棒」）；
/// ② 没配 API Key 时兜底话术也要给具体数字，而不是「我不明白」；
/// ③ 陪伴数据不可同步（插件边界与双链笔记一致）。
void main() {
  final service = CompanionService.instance;

  CompanionSnapshot snap({
    int streak = 0,
    int today = 0,
    int week = 0,
    double accuracy = 0,
    int due = 0,
  }) =>
      CompanionSnapshot(
        streakDays: streak,
        todayAnswered: today,
        weekAnswered: week,
        weekAccuracy: accuracy,
        dueReviews: due,
      );

  group('场景判定', () {
    test('空库 → fresh', () {
      expect(CompanionSnapshot.empty.scene, CompanionScene.fresh);
    });

    test('有连胜、今天没开始 → idle（提醒别断签）', () {
      expect(snap(streak: 6).scene, CompanionScene.idle);
    });

    test('今天在刷但未达标 → onTrack', () {
      expect(snap(streak: 6, today: 18, week: 120, accuracy: 72).scene,
          CompanionScene.onTrack);
    });

    test('今日 50 题达标 → goalReached', () {
      expect(snap(today: 52).scene, CompanionScene.goalReached);
      expect(snap(today: 50).reachedGoal, isTrue);
    });

    test('本周正确率 < 60%（样本 ≥ 10）→ lowAccuracy 优先于待复习', () {
      expect(snap(week: 40, accuracy: 45, due: 30).scene,
          CompanionScene.lowAccuracy);
      // 样本不足时不算正确率低
      expect(snap(week: 4, accuracy: 25).scene, CompanionScene.fresh);
    });

    test('待复习 ≥ 20 → reviewBacklog', () {
      expect(snap(due: 20).scene, CompanionScene.reviewBacklog);
      expect(snap(due: 19).scene, CompanionScene.fresh);
    });

    test('本周没有样本时正确率显示「—」而不是 0.0%', () {
      expect(CompanionSnapshot.empty.weekAccuracyText, '—');
      expect(snap(week: 10, accuracy: 82.5).weekAccuracyText, '82.5%');
    });
  });

  group('脚本台词与快捷问句', () {
    test('每个场景都有台词，情绪与场景匹配', () {
      final cases = {
        CompanionScene.fresh: CompanionMood.idle,
        CompanionScene.idle: CompanionMood.cheer,
        CompanionScene.onTrack: CompanionMood.happy,
        CompanionScene.goalReached: CompanionMood.proud,
        CompanionScene.lowAccuracy: CompanionMood.worried,
        CompanionScene.reviewBacklog: CompanionMood.worried,
      };
      final fixtures = {
        CompanionScene.fresh: snap(),
        CompanionScene.idle: snap(streak: 3),
        CompanionScene.onTrack: snap(today: 10),
        CompanionScene.goalReached: snap(today: 50),
        CompanionScene.lowAccuracy: snap(week: 20, accuracy: 40),
        CompanionScene.reviewBacklog: snap(due: 25),
      };
      cases.forEach((scene, mood) {
        final lines = service.linesFor(fixtures[scene]!);
        expect(lines, isNotEmpty, reason: '场景 $scene 缺少台词');
        expect(lines.every((l) => l.mood == mood), isTrue,
            reason: '场景 $scene 的情绪应为 $mood');
        expect(lines.every((l) => l.text.trim().isNotEmpty), isTrue);
      });
    });

    test('greet 用注入的 Random 做确定性选择', () {
      final s = snap(streak: 4, today: 0);
      final a = service.greet(s, rng: Random(7));
      final b = service.greet(s, rng: Random(7));
      expect(a.text, b.text);
      expect(a.text.trim(), isNotEmpty);
      // 「第 N+1 天」的台词把连胜算进去了（4 天 → 第 5 天）
      expect(service.linesFor(s)[1].text, contains('第 5 天'));
    });

    test('台词里带真实数字而不是套话', () {
      final onTrack = service.linesFor(snap(today: 32)).first.text;
      expect(onTrack, contains('32'));
      expect(onTrack, contains('50'));
      final backlog = service.linesFor(snap(due: 23)).first.text;
      expect(backlog, contains('23'));
    });

    test('快捷问句随状态变化（有待复习才有「先复习错题」）', () {
      expect(service.quickPrompts(snap()), isNot(contains('先复习错题')));
      expect(service.quickPrompts(snap(due: 5)), contains('先复习错题'));
      expect(service.quickPrompts(snap(week: 20, accuracy: 55)),
          contains('怎么提高正确率'));
      expect(service.quickPrompts(snap()), contains('夸夸我'));
    });
  });

  group('兜底回复（未配置 AI / 请求失败时）', () {
    test('累了先劝休息，并复述今天的题量', () {
      final reply = service.fallbackReply('我好累啊', snap(today: 12));
      expect(reply, contains('先停一下'));
      expect(reply, contains('12'));
    });

    test('求夸时用真实的连胜与今日题量', () {
      final reply = service.fallbackReply('夸夸我', snap(streak: 5, today: 20));
      expect(reply, contains('5'));
      expect(reply, contains('20'));
      expect(reply, contains('作证'));
    });

    test('说到错题时把待复习数报出来', () {
      final reply = service.fallbackReply('我错好多', snap(due: 12));
      expect(reply, contains('12'));
      expect(reply, contains('10'));
    });

    test('问计划时给出今天能执行的动作', () {
      expect(service.fallbackReply('今天学什么', snap(today: 10)),
          contains('还差 40 题'));
      expect(service.fallbackReply('今天学什么', snap(due: 30)), contains('30'));
    });

    test('没有关键词也会回到当前场景台词，不会说「我不明白」', () {
      final reply = service.fallbackReply('随便聊聊', snap(today: 8));
      expect(reply.contains('不明白'), isFalse);
      expect(reply, isNotEmpty);
    });
  });

  group('提示词', () {
    test('人设写清四件事：名字、简短、不编数字、不做诊断', () {
      final prompt = service.systemPrompt();
      expect(prompt, contains(CompanionService.personaName));
      expect(prompt, contains('不要编造'));
      expect(prompt, contains('医疗诊断'));
      expect(prompt, contains('2~3 句'));
    });

    test('用户侧提示词带全部真实统计与约束', () {
      final prompt = service.buildPrompt(
        snapshot: snap(streak: 3, today: 18, week: 120, accuracy: 72.5, due: 7),
        userText: '今天学什么',
        nickname: '安安',
      );
      expect(prompt, contains('安安'));
      expect(prompt, contains('连续打卡：3 天'));
      expect(prompt, contains('今天已答：18 题'));
      expect(prompt, contains('正确率 72.5%'));
      expect(prompt, contains('待复习：7 题'));
      expect(prompt, contains('今天学什么'));
    });
  });

  group('好感度状态（settings 一行 JSON）', () {
    test('JSON 往返保持字段', () {
      const state = CompanionState(affection: 12, talks: 4, lastDay: '2026-10-29');
      final back = CompanionState.fromJson(state.toJson());
      expect(back.affection, 12);
      expect(back.talks, 4);
      expect(back.lastDay, '2026-10-29');
    });

    test('脏数据 / 越界值被夹住，不抛异常', () {
      final back = CompanionState.fromJson({
        'affection': 5000,
        'talks': '-3',
        'last_day': '',
      });
      expect(back.affection, CompanionState.maxAffection);
      expect(back.talks, 0);
      expect(back.lastDay, isNull);
    });
  });

  group('插件登记 / 数据层', () {
    setUp(() async {
      await DatabaseService.instance.close();
      final dir = Directory(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
      final dbPath = '${dir.path}/natsume_quiz_master/'
          'test_companion_${DateTime.now().microsecondsSinceEpoch}.db';
      DatabaseService.overrideDbPath = dbPath;
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
    });

    test('插件清单：随 App 出厂、声明可同步范围、注明取形来源', () {
      expect(BuiltinPlugins.companionId, 'natsume.companion');
      // 出厂三件套：双链笔记 / 小鲸助教 / 日程待办（v1.34）
      expect(BuiltinPlugins.all.length, 3);
      // v1.35：人设与记忆可随局域网同步（Key / 好感度仍只留本机）
      expect(BuiltinPlugins.companion.syncable, isTrue);
      expect(BuiltinPlugins.companion.manifestMap['syncable'], isTrue);
      expect(BuiltinPlugins.companion.license, 'AGPL-3.0');
      expect(BuiltinPlugins.companion.upstream, contains('Coopanion'));
      expect(CompanionService.syncable, isTrue);
      // 日程插件同样可同步（v17 起 schedule_items 带 uid）
      expect(BuiltinPlugins.scheduleId, 'natsume.schedule');
      expect(BuiltinPlugins.schedule.syncable, isTrue);
      expect(BuiltinPlugins.schedule.manifestMap['syncable'], isTrue);
      expect(BuiltinPlugins.byId(BuiltinPlugins.scheduleId), isNotNull);
      // 素材边界：上游鲸鱼娘贴图不在 AGPL 范围内，本工程不得携带其图像
      expect(Directory('assets/companion').existsSync(), isFalse,
          reason: '陪伴插件只允许自绘头像，不得打包上游 web/whale 贴图');
    });

    test('ensureRegistered 幂等，且保留用户停用状态', () async {
      await BuiltinPlugins.ensureRegistered();
      await BuiltinPlugins.setEnabled(BuiltinPlugins.companionId, false);
      await BuiltinPlugins.ensureRegistered();
      final plugins = await DatabaseService.instance.getAllPlugins();
      final row =
          plugins.firstWhere((p) => p.id == BuiltinPlugins.companionId);
      expect(row.enabled, isFalse);
      expect(await BuiltinPlugins.isEnabled(BuiltinPlugins.companionId),
          isFalse);
    });

    test('空库快照全 0（不会凭空夸人）', () async {
      final s = await service.snapshot(AppState());
      expect(s.streakDays, 0);
      expect(s.todayAnswered, 0);
      expect(s.weekAnswered, 0);
      expect(s.dueReviews, 0);
      expect(s.scene, CompanionScene.fresh);
    });

    test('recordTalk：当天第一次 +3，同日再次 +1，隔天重新 +3', () async {
      final day1 = DateTime(2026, 10, 29, 9);
      final first = await service.recordTalk(now: day1);
      expect(first.affection, 3);
      expect(first.talks, 1);
      expect(first.lastDay, '2026-10-29');

      final second =
          await service.recordTalk(now: day1.add(const Duration(hours: 2)));
      expect(second.affection, 4);
      expect(second.talks, 2);

      final nextDay = await service.recordTalk(now: DateTime(2026, 10, 30, 8));
      expect(nextDay.affection, 7);
      expect(nextDay.lastDay, '2026-10-30');
    });

    test('脏 JSON 回落空状态；reset 清空', () async {
      await DatabaseService.instance
          .setSetting(CompanionService.stateKey, '{oops');
      expect((await service.loadState()).affection, 0);

      await service.saveState(const CompanionState(affection: 9, talks: 2));
      expect((await service.loadState()).affection, 9);

      await service.reset();
      expect((await service.loadState()).affection, 0);
    });
  });
}
