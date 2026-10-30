import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/companion.dart';
import 'package:natsume_quiz_master/models/companion_memory.dart';
import 'package:natsume_quiz_master/models/companion_settings.dart';
import 'package:natsume_quiz_master/services/companion/companion_service.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// v1.33「悬浮小鲸」的契约测试。
///
/// 守四件事：
/// ① 设置怎么存都得「还能打开」——脏 JSON、越界数值一律回落默认；
/// ② Key 落盘必须是密文，解密后能还原（备份文件里不该出现明文）；
/// ③ 记忆是环形的、有硬上限的，长期摘要只写真实统计；
/// ④ 语气与人设可配，但「不编造数字 / 不给医疗建议」两条硬约束不能被覆盖。
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

  group('CompanionSettings：默认值与序列化', () {
    test('默认值：悬浮开、10 分钟、温柔、跟随软件、可查资料', () {
      const s = CompanionSettings.defaults;
      expect(s.overlayEnabled, isTrue);
      expect(s.bubbleMinutes, 10);
      expect(s.tone, CompanionTone.gentle);
      expect(s.displayName, CompanionSettings.defaultBotName);
      expect(s.apiMode, CompanionApiMode.followApp);
      expect(s.kbEnabled, isTrue);
      expect(s.memoryEnabled, isTrue);
      expect(s.hasOwnApi, isFalse);
      expect(s.kbId, isNull);
      expect(s.hiddenDay, isNull);
    });

    test('JSON 往返：Key 落盘是密文，解回来是原文', () {
      const s = CompanionSettings(
        overlayEnabled: false,
        bubbleMinutes: 30,
        tone: CompanionTone.strict,
        botName: '溟月',
        customPersona: '说话简短一点，别用感叹号',
        memoryEnabled: false,
        apiMode: CompanionApiMode.custom,
        providerKind: AiProviderKind.anthropic,
        endpoint: 'https://example.test/v1',
        model: 'claude-mini',
        apiKey: 'sk-secret-123',
        kbEnabled: false,
        kbId: 7,
        overlayX: 0.25,
        overlayY: 0.8,
        hiddenDay: '2026-10-29',
      );
      final json = s.toJson();
      // 加密落盘：序列化结果里不能出现明文 Key
      expect(jsonEncode(json), isNot(contains('sk-secret-123')));

      final back = CompanionSettings.fromJson(Map<String, dynamic>.from(json));
      expect(back.overlayEnabled, isFalse);
      expect(back.bubbleMinutes, 30);
      expect(back.tone, CompanionTone.strict);
      expect(back.botName, '溟月');
      expect(back.customPersona, '说话简短一点，别用感叹号');
      expect(back.memoryEnabled, isFalse);
      expect(back.apiMode, CompanionApiMode.custom);
      expect(back.providerKind, AiProviderKind.anthropic);
      expect(back.endpoint, 'https://example.test/v1');
      expect(back.model, 'claude-mini');
      expect(back.apiKey, 'sk-secret-123');
      expect(back.kbEnabled, isFalse);
      expect(back.kbId, 7);
      expect(back.overlayX, closeTo(0.25, 1e-9));
      expect(back.overlayY, closeTo(0.8, 1e-9));
      expect(back.hiddenDay, '2026-10-29');
    });

    test('脏数据 / 越界值被夹住，不抛异常', () {
      final back = CompanionSettings.fromJson(<String, dynamic>{
        'bubble_minutes': 7, // 不在白名单：回落 10
        'tone': 'not-a-tone',
        'bot_name': '一' * 20,
        'custom_persona': 'x' * 5000,
        'api_mode': 'not-a-mode',
        'provider': 'not-a-provider',
        'kb_id': 0, // 0 视为「全部」
        'overlay_x': 5,
        'overlay_y': -3,
        'hidden_day': '   ',
        'memory': 'false',
      });
      expect(back.bubbleMinutes, 10);
      expect(back.tone, CompanionTone.gentle);
      expect(back.displayName.length, CompanionSettings.maxNameChars);
      expect(back.customPersona.length, CompanionSettings.maxPersonaChars);
      expect(back.apiMode, CompanionApiMode.followApp);
      expect(back.providerKind, AiProviderKind.openaiCompat);
      expect(back.kbId, isNull);
      expect(back.overlayX, 1.0);
      expect(back.overlayY, 0.0);
      expect(back.hiddenDay, isNull);
      expect(back.memoryEnabled, isFalse);
    });

    test('空名字回落默认，气泡频率 0 = 关闭', () {
      final s = CompanionSettings.fromJson(<String, dynamic>{'bot_name': '  '});
      expect(s.displayName, CompanionSettings.defaultBotName);
      expect(s.copyWith(bubbleMinutes: 0).bubblesEnabled, isFalse);
      expect(s.copyWith(bubbleMinutes: 30).bubblesEnabled, isTrue);
    });
  });

  group('CompanionSettings：接口解析与「今天别出现」', () {
    test('独立模式没填 Key 时仍然跟随软件（不会把聊天聊成 401）', () {
      final app = AppSettings(apiKey: 'app-key', nickname: '阿秋');
      const noKey = CompanionSettings(
        apiMode: CompanionApiMode.custom,
        model: 'cheap-model',
      );
      expect(noKey.hasOwnApi, isFalse);
      expect(noKey.resolve(app).apiKey, 'app-key');
      expect(noKey.resolve(app).model, AppSettings.defaultModel);
    });

    test('独立模式填了 Key：覆盖地址/模型/提供方，但不冲掉其它全局字段', () {
      final app = AppSettings(
        apiKey: 'app-key',
        nickname: '阿秋',
        keywordHighlight: false,
        model: 'app-model',
      );
      const own = CompanionSettings(
        apiMode: CompanionApiMode.custom,
        apiKey: 'own-key',
        providerKind: AiProviderKind.gemini,
      );
      final merged = own.resolve(app);
      expect(merged.apiKey, 'own-key');
      expect(merged.providerKind, AiProviderKind.gemini);
      expect(merged.apiEndpoint, AppSettings.defaultApiEndpoint);
      expect(merged.model, AppSettings.defaultModel);
      // 与聊天无关的字段原样保留
      expect(merged.nickname, '阿秋');
      expect(merged.keywordHighlight, isFalse);
    });

    test('「今天先别出现」只记日期，撤回时不顺手关掉母开关', () {
      const s = CompanionSettings(overlayEnabled: true, hiddenDay: '2026-10-29');
      expect(s.hiddenOn('2026-10-29'), isTrue);
      expect(s.hiddenOn('2026-10-30'), isFalse);

      final back = s.copyWith(hiddenDay: () => null);
      expect(back.hiddenDay, isNull);
      expect(back.overlayEnabled, isTrue);
      // 清空知识库选择同理：闭包参数区分「不改」与「清空」
      expect(s.copyWith(kbId: () => null).kbId, isNull);
      expect(s.copyWith(kbId: () => 3).kbId, 3);
    });
  });

  group('CompanionMemory：环形记忆与客观摘要', () {
    test('超过上限只保留最近的 40 条', () {
      final m = CompanionMemory.fresh();
      for (var i = 0; i < CompanionMemory.maxTurns + 5; i++) {
        m.add(fromUser: i.isEven, text: '第 $i 条', now: DateTime(2026, 10, 29));
      }
      expect(m.length, CompanionMemory.maxTurns);
      expect(m.turns.first.text, '第 5 条');
      expect(m.turns.last.text, '第 44 条');
    });

    test('空白不记；超长单条截断；跨天带上日期键', () {
      final m = CompanionMemory.fresh();
      m.add(fromUser: true, text: '   ');
      expect(m.isEmpty, isTrue);

      m.add(fromUser: true, text: 'A' * 900, now: DateTime(2026, 10, 29, 9));
      expect(m.length, 1);
      expect(m.turns.single.text.length, CompanionMemory.maxTurnChars + 1);
      expect(m.turns.single.text.endsWith('…'), isTrue);
      expect(m.turns.single.day, '2026-10-29');
      expect(m.turns.single.role, 'user');
    });

    test('摘要只用真实统计重算（不保留模型自己说的数字）', () {
      final m = CompanionMemory.fresh();
      m.refreshSummary(snap(streak: 3, today: 12, week: 40, accuracy: 75, due: 9),
          nickname: '阿秋');
      expect(m.summary, contains('连续打卡 3 天'));
      expect(m.summary, contains('12/${CompanionSnapshot.dailyGoal}'));
      expect(m.summary, contains('75.0%'));
      expect(m.summary, contains('错题待到复习 9 题'));

      m.refreshSummary(snap(), nickname: '阿秋');
      expect(m.summary, contains('连续打卡 0 天'));
      expect(m.summary, isNot(contains('3 天')));
    });

    test('contextBlock：空记忆返回空串，有内容时只带最近几轮', () {
      final m = CompanionMemory.fresh();
      expect(m.contextBlock(), '');

      for (var i = 0; i < 10; i++) {
        m.add(fromUser: true, text: '问题 $i', now: DateTime(2026, 10, 29));
      }
      m.refreshSummary(snap(streak: 2), nickname: '阿秋');
      final block = m.contextBlock(botName: '溟月', last: 3);
      expect(block, contains('# 长期记忆'));
      expect(block, contains('连续打卡 2 天'));
      expect(block, contains('问题 9'));
      expect(block, isNot(contains('问题 6')));
    });

    test('JSON 往返：坏行跳过，脏摘要 trim', () {
      final m = CompanionMemory(
        turns: [
          const CompanionTurn(fromUser: true, text: '你好', day: '2026-10-29'),
          const CompanionTurn(fromUser: false, text: '在的', day: '2026-10-29'),
        ],
        summary: '  摘要  ',
      );
      final back = CompanionMemory.fromJson(
          Map<String, dynamic>.from(jsonDecode(jsonEncode(m.toJson())) as Map));
      expect(back.length, 2);
      expect(back.summary, '摘要');
      expect(back.turns[1].fromUser, isFalse);
      expect(back.turns[1].role, 'bot');

      final dirty = CompanionMemory.fromJson(<String, dynamic>{
        'summary': 123,
        'turns': [
          {'role': 'user', 'text': '   '},
          {'text': '保留我'},
          'not-a-map',
          null,
        ],
      });
      expect(dirty.length, 1);
      expect(dirty.turns.single.text, '保留我');
      expect(dirty.summary, '123');
    });

    test('clear 清空原文与摘要', () {
      final m = CompanionMemory.fresh();
      m.add(fromUser: true, text: '在吗');
      m.refreshSummary(snap(streak: 1));
      m.clear();
      expect(m.isEmpty, isTrue);
      expect(m.contextBlock(), '');
    });
  });

  group('提示词：语气可配，硬约束不放开', () {
    test('四种语气都能落到提示词上，且都带着数据真实与医疗安全约束', () {
      for (final tone in CompanionTone.values) {
        final prompt = service.systemPrompt(
            settings: CompanionSettings(tone: tone, botName: '溟月'));
        expect(prompt, contains('你是「溟月」'), reason: '语气 $tone 丢了角色名');
        expect(prompt, contains(tone.promptClause), reason: '语气 $tone 没进提示词');
        expect(prompt, contains('不要编造任何题目数'));
        expect(prompt, contains('不给医疗诊断'));
      }
    });

    test('自定义人设单独成块，并声明不得违反硬约束', () {
      final prompt = service.systemPrompt(
          settings: const CompanionSettings(customPersona: '说话像学姐，简短一点'));
      expect(prompt, contains('说话像学姐，简短一点'));
      expect(prompt, contains('# 用户自定义人设'));
      expect(prompt, contains('不得违反上面的数据真实性与医疗安全约束'));

      // 没填人设时不该出现空区块
      expect(service.systemPrompt(), isNot(contains('用户自定义人设')));
    });

    test('displayName 跟着设置走，空值回落默认', () {
      expect(
          service.displayName(const CompanionSettings(botName: '溟月')), '溟月');
      expect(service.displayName(const CompanionSettings(botName: '   ')),
          CompanionSettings.defaultBotName);
      expect(service.displayName(), CompanionSettings.defaultBotName);
    });

    test('buildPrompt：数字来自快照，记忆与知识库按需拼入', () {
      final s = snap(streak: 5, today: 20, week: 120, accuracy: 81.5, due: 4);
      final base = service.buildPrompt(snapshot: s, userText: '我有点慌');
      expect(base, contains('连续打卡：5 天'));
      expect(base, contains('今天已答：20 题'));
      expect(base, contains('81.5%'));
      expect(base, contains('我有点慌'));
      // 没记忆、没资料时结构与 v1.32 一致：不多出空区块
      expect(base, isNot(contains('# 最近的对话')));
      expect(base, isNot(contains('知识库资料')));

      final memory = CompanionMemory.fresh()
        ..add(fromUser: true, text: '上次说到第三章')
        ..refreshSummary(s, nickname: '阿秋');
      final withExtras = service.buildPrompt(
        snapshot: s,
        userText: '接着来',
        settings: const CompanionSettings(memoryEnabled: true),
        memory: memory,
        kbBlock: '# 知识库资料（用户导入，真实性优先）\n【资料1】动作电位指……',
      );
      expect(withExtras, contains('上次说到第三章'));
      expect(withExtras, contains('【资料1】动作电位'));
      expect(withExtras, contains('依据你导入的资料'));

      expect(
          service.buildPrompt(snapshot: s, userText: 'hi', nickname: '阿秋'),
          contains('称呼：阿秋'));
    });
  });

  group('落盘：设置与记忆（settings 表，不涨 schema）', () {
    setUp(() async {
      await DatabaseService.instance.close();
      final dir = Directory(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
      final dbPath = '${dir.path}/natsume_quiz_master/'
          'test_companion_settings_${DateTime.now().microsecondsSinceEpoch}.db';
      DatabaseService.overrideDbPath = dbPath;
      final f = File(dbPath);
      if (await f.exists()) await f.delete();
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
    });

    test('保存 → 读取：人格与 Key 都还原，落盘是密文', () async {
      const s = CompanionSettings(
        tone: CompanionTone.coach,
        botName: '溟月',
        bubbleMinutes: 20,
        apiMode: CompanionApiMode.custom,
        apiKey: 'sk-live-1',
      );
      await service.saveSettings(s);

      final raw =
          await DatabaseService.instance.getSetting(CompanionService.settingsKey);
      expect(raw, isNotNull);
      expect(raw, isNot(contains('sk-live-1')));

      final back = await service.loadSettings();
      expect(back.tone, CompanionTone.coach);
      expect(back.displayName, '溟月');
      expect(back.bubbleMinutes, 20);
      expect(back.apiKey, 'sk-live-1');
    });

    test('脏 JSON 回落默认设置（设置坏了也要能打开助教）', () async {
      await DatabaseService.instance
          .setSetting(CompanionService.settingsKey, '{oops');
      final back = await service.loadSettings();
      expect(back.tone, CompanionTone.gentle);
      expect(back.overlayEnabled, isTrue);
      expect(back.apiMode, CompanionApiMode.followApp);
    });

    test('remember 落盘：原文 + 摘要都在，clearMemory 清空', () async {
      var memory = await service.loadMemory();
      expect(memory.isEmpty, isTrue);

      memory = await service.remember(
        memory,
        fromUser: true,
        text: '今天只做了 10 题',
        snapshot: snap(streak: 2, today: 10),
        nickname: '阿秋',
        now: DateTime(2026, 10, 29),
      );
      memory = await service.remember(
        memory,
        fromUser: false,
        text: '那明天先做 5 题热热身',
        snapshot: snap(streak: 2, today: 10),
        nickname: '阿秋',
        now: DateTime(2026, 10, 29),
      );

      final back = await service.loadMemory();
      expect(back.length, 2);
      expect(back.turns.first.text, '今天只做了 10 题');
      expect(back.turns.last.fromUser, isFalse);
      expect(back.summary, contains('连续打卡 2 天'));

      await service.clearMemory();
      expect((await service.loadMemory()).isEmpty, isTrue);
    });

    test('knowledgeBlock：关掉 / 空问题 / 没有知识库时都返回空串', () async {
      // 关掉知识库：一次都不查
      expect(
          await service.knowledgeBlock('动作电位',
              settings: const CompanionSettings(kbEnabled: false)),
          '');
      // 空问题不查
      expect(await service.knowledgeBlock('   '), '');
      // 库是空的：检索不到也不能抛，聊天照常走通用知识
      expect(await service.knowledgeBlock('动作电位'), '');
    });
  });
}
