import 'dart:convert';
import 'dart:math';

import '../../models/companion.dart';
import '../../models/companion_memory.dart';
import '../../models/companion_settings.dart';
import '../app_state.dart';
import '../database_service.dart';
import '../knowledge_base/kb_retriever.dart';
import '../knowledge_base/kb_service.dart';

/// 学习陪伴插件（v1.32 · 「小鲸助教」）服务层。
///
/// 设计取舍（对着 Coopanion 抄「结构」而不抄「代码与素材」）：
/// - **状态来源是真实统计**：连胜、今日题量、本周正确率、错题到期数全部取自
///   既有 `AppState` 接口，不新造一套「经验值」，避免出现「App 说我很努力、
///   统计页说我这周没刷题」的自相矛盾；
/// - **先脚本、再 AI**：没有配 API Key / AI 请求失败时，用 [greet] /
///   [fallbackReply] 的固定文案兜底，功能不会因为没网就变砖；
/// - **插件数据不同步**：与双链笔记同一条边界（[syncable] = false），界面上
///   凡出现陪伴内容都写明「无法同步」。
///
/// 取形来源：Coopanion（AGPL-3.0-or-later）的桌宠/好感度思路；未引入其
/// 任何代码与图像资源，详见 `CompanionSnapshot` 的类注释与
/// THIRD_PARTY_NOTICES.md。
class CompanionService {
  CompanionService._();
  static final CompanionService instance = CompanionService._();

  static final DatabaseService _db = DatabaseService.instance;

  /// 陪伴数据是否参与局域网同步（false = 换设备看不到，界面要明说）
  static const bool syncable = false;

  /// 界面统一复用的同步提示文案
  static const String syncNotice = '聊天与好感度只保存在本机，不参与局域网同步';

  /// 角色名（头像、气泡、插件说明共用）
  static const String personaName = '小鲸';

  /// 陪伴状态在 settings 表里的键（一行 JSON，避免为几个字段再涨 schema）
  static const String stateKey = 'companion_state_v1';

  /// 陪伴设置（v1.33：人格 / 接口 / 气泡 / 知识库）在 settings 表里的键
  static const String settingsKey = 'companion_settings_v1';

  /// 对话记忆（v1.33：最近 40 轮 + 客观摘要）在 settings 表里的键
  static const String memoryKey = 'companion_memory_v1';

  /// 悬浮头像用的图片：直接复用 App 图标，不再引入第三方素材
  /// （v1.33 用户原话：「用软件的图标也可以」）。
  static const String avatarAsset = 'assets/app_logo.png';

  /// 与 `CompanionSnapshot.dailyGoal` 同值的本地别名，文案里直接用
  static const int dailyGoal = CompanionSnapshot.dailyGoal;

  // ======================== 状态快照 ========================

  /// 从既有统计拼出快照。任一查询失败都按 0 处理：陪伴页是「锦上添花」，
  /// 不该因为某个统计出错就打不开。
  Future<CompanionSnapshot> snapshot(AppState app) async {
    var streak = 0;
    var today = 0;
    var weekAnswered = 0;
    var weekAccuracy = 0.0;
    var due = 0;
    try {
      streak = await app.getStreakDays();
      final daily = await app.getDailyStats(1);
      if (daily.isNotEmpty) today = (daily.last['total'] as int?) ?? 0;
      final week = await app.getPeriodStats('week');
      weekAnswered = week.totalQuestions;
      weekAccuracy = week.accuracy;
      final byBank = await app.getErrorBookStats();
      for (final row in byBank) {
        due += (row['due_count'] as int?) ?? 0;
      }
    } catch (_) {
      // 统计不可用：返回已经取到的部分，界面照常显示
    }
    return CompanionSnapshot(
      streakDays: streak,
      todayAnswered: today,
      weekAnswered: weekAnswered,
      weekAccuracy: weekAccuracy,
      dueReviews: due,
    );
  }

  // ======================== 脚本台词 ========================

  /// 当前场景下可用的打气台词（顺序固定，随机只发生在 [greet] 里）
  List<CompanionLine> linesFor(CompanionSnapshot s, {String? nickname}) {
    final who = (nickname == null || nickname.trim().isEmpty) ? '你' : nickname;
    final remain = (dailyGoal - s.todayAnswered).clamp(0, dailyGoal);
    switch (s.scene) {
      case CompanionScene.fresh:
        return [
          const CompanionLine(
              '你好呀，我是小鲸。今天先来 5 道题试试水好吗？我陪着你。',
              CompanionMood.idle),
          CompanionLine('题库已经准备好了，$who 只要开始第一题，今天就算开张。',
              CompanionMood.idle),
          const CompanionLine('第一次见面～要不要先做 1 道题？让我看看你更擅长哪一科。',
              CompanionMood.idle),
        ];
      case CompanionScene.idle:
        return [
          CompanionLine('你已经连续打卡 ${s.streakDays} 天啦，今天还差一点就断在这里。',
              CompanionMood.cheer),
          CompanionLine('第 ${s.streakDays + 1} 天的小鲸在等你：先刷 10 题热身怎么样？',
              CompanionMood.cheer),
          CompanionLine('今天还没开张哦。之前连着 ${s.streakDays} 天，别让它停在今天。',
              CompanionMood.cheer),
        ];
      case CompanionScene.onTrack:
        return [
          CompanionLine('已经 ${s.todayAnswered} 题啦，再 $remain 题就到今天的 50 题线，稳的。',
              CompanionMood.happy),
          CompanionLine('这个节奏很好，$remain 题之后今天的打卡就拿到了。',
              CompanionMood.happy),
          CompanionLine('${s.todayAnswered} / $dailyGoal，差一点点，我在这边等你写完。',
              CompanionMood.happy),
        ];
      case CompanionScene.goalReached:
        return [
          CompanionLine('今天 50 题达标！连续 ${s.streakDays} 天，我记下来了。',
              CompanionMood.proud),
          CompanionLine('收工撒花～今天一共 ${s.todayAnswered} 题，去休息一下吧。',
              CompanionMood.proud),
          CompanionLine('目标达成，${s.todayAnswered} 题到手。明天我还在这里。',
              CompanionMood.proud),
        ];
      case CompanionScene.lowAccuracy:
        return [
          CompanionLine(
              '本周正确率 ${s.weekAccuracyText}，先别急，错题本里正好有 ${s.dueReviews} 道到期题。',
              CompanionMood.worried),
          const CompanionLine('正确率偏低的时候，复习错题比再刷 50 道新题管用得多。',
              CompanionMood.worried),
          CompanionLine('把错题过一遍再看新题，正确率会自己回来的（${s.weekAccuracyText} 起）。',
              CompanionMood.worried),
        ];
      case CompanionScene.reviewBacklog:
        return [
          CompanionLine('待复习已经 ${s.dueReviews} 道了，先清 10 道，我陪你数。',
              CompanionMood.worried),
          CompanionLine('错题堆着会越滚越大，今天先还 10 道债好吗？（共 ${s.dueReviews} 道）',
              CompanionMood.worried),
          CompanionLine('到期 ${s.dueReviews} 道题在排队，清一小批也比一直拖强。',
              CompanionMood.worried),
        ];
    }
  }

  /// 见面第一句（随机取一条；[rng] 可注入，测试据此固定选择）
  CompanionLine greet(CompanionSnapshot s, {String? nickname, Random? rng}) {
    final pool = linesFor(s, nickname: nickname);
    final r = rng ?? Random();
    return pool[r.nextInt(pool.length)];
  }

  /// 快捷问句（点一下就发，降低「不知道跟 bot 聊什么」的门槛）
  List<String> quickPrompts(CompanionSnapshot s) {
    final list = <String>[];
    if (s.dueReviews > 0) list.add('先复习错题');
    list.add('今天学什么');
    if (s.weekAnswered >= 10 && s.weekAccuracy < 80) {
      list.add('怎么提高正确率');
    }
    list
      ..add('夸夸我')
      ..add('我有点累');
    return list;
  }

  // ======================== 状态读写 ========================

  Future<CompanionState> loadState() async {
    final raw = await _db.getSetting(stateKey);
    if (raw == null || raw.trim().isEmpty) return CompanionState.empty;
    try {
      final data = jsonDecode(raw);
      if (data is Map) {
        return CompanionState.fromJson(
            data.map((k, v) => MapEntry<String, dynamic>('$k', v)));
      }
    } catch (_) {
      // 脏数据：当作全新状态，不抛
    }
    return CompanionState.empty;
  }

  Future<void> saveState(CompanionState state) =>
      _db.setSetting(stateKey, jsonEncode(state.toJson()));

  /// 记一次互动：每天第一次见面 +3，其后每次 +1（上限
  /// [CompanionState.maxAffection]）。返回更新后的状态供界面刷新。
  Future<CompanionState> recordTalk({DateTime? now}) async {
    final ts = now ?? DateTime.now();
    final today = companionDayKey(ts);
    final current = await loadState();
    final firstToday = current.lastDay != today;
    final next = current.copyWith(
      affection: (current.affection + (firstToday ? 3 : 1))
          .clamp(0, CompanionState.maxAffection),
      talks: current.talks + 1,
      lastDay: today,
    );
    await saveState(next);
    return next;
  }

  /// 清空陪伴状态（用户在页面里点「重新认识」时调用）
  Future<void> reset() => _db.setSetting(stateKey, '');

  // ======================== 设置读写（v1.33） ========================

  /// 读陪伴设置；没有记录 / 脏数据一律回落默认值。
  ///
  /// 注意：这个方法是给 `AppState.init()` 和设置页用的。悬浮层不直接读
  /// 数据库，而是读 `AppState.companionSettings`——挂在 MaterialApp.builder
  /// 上的浮层每帧都可能在 build，不能在里面发起 IO。
  Future<CompanionSettings> loadSettings() async {
    final raw = await _db.getSetting(settingsKey);
    if (raw == null || raw.trim().isEmpty) return CompanionSettings.defaults;
    try {
      final data = jsonDecode(raw);
      if (data is Map) {
        return CompanionSettings.fromJson(
            data.map((k, v) => MapEntry<String, dynamic>('$k', v)));
      }
    } catch (_) {
      // 脏数据：按默认设置走，不抛
    }
    return CompanionSettings.defaults;
  }

  Future<void> saveSettings(CompanionSettings settings) =>
      _db.setSetting(settingsKey, jsonEncode(settings.toJson()));

  // ======================== 记忆读写（v1.33） ========================

  Future<CompanionMemory> loadMemory() async {
    final raw = await _db.getSetting(memoryKey);
    if (raw == null || raw.trim().isEmpty) return CompanionMemory();
    try {
      final data = jsonDecode(raw);
      if (data is Map) {
        return CompanionMemory.fromJson(
            data.map((k, v) => MapEntry<String, dynamic>('$k', v)));
      }
    } catch (_) {
      // 脏数据：当作没有记忆，不让聊天打不开
    }
    return CompanionMemory();
  }

  Future<void> saveMemory(CompanionMemory memory) =>
      _db.setSetting(memoryKey, jsonEncode(memory.toJson()));

  Future<void> clearMemory() => _db.setSetting(memoryKey, '');

  /// 记一条对话并落盘（长期摘要用当前统计重算，保证记忆里的数字是真的）
  Future<CompanionMemory> remember(
    CompanionMemory memory, {
    required bool fromUser,
    required String text,
    required CompanionSnapshot snapshot,
    String? nickname,
    DateTime? now,
  }) async {
    memory.add(fromUser: fromUser, text: text, now: now);
    memory.refreshSummary(snapshot, nickname: nickname);
    await saveMemory(memory);
    return memory;
  }

  // ======================== 知识库接地（v1.33） ========================

  /// 为陪伴对话检索知识库，返回可直接拼进 [buildPrompt] 的资料块。
  ///
  /// 与出题用的 `GroundingService` 是**两种强度**：出题要求「只允许依据
  /// 资料」，而聊天里用户往往只是想聊天，硬约束会让 bot 一直回「资料未
  /// 提及」。所以这里用软约束：优先引资料，覆盖不到的部分可以按通用知识
  /// 回答，但必须声明。任何异常（没有知识库、检索失败、引擎未就绪）都返回
  /// 空串——聊天不该因为知识库坏了而打不开。
  Future<String> knowledgeBlock(
    String query, {
    CompanionSettings? settings,
    int topK = 3,
    int maxCharsPerHit = 600,
  }) async {
    final cs = settings ?? CompanionSettings.defaults;
    final text = query.trim();
    if (!cs.kbEnabled || text.isEmpty) return '';
    try {
      final kbSvc = KbService.instance;
      final ids = <int>[];
      if (cs.kbId != null) {
        ids.add(cs.kbId!);
      } else {
        for (final kb in await kbSvc.listKnowledgeBases()) {
          final id = kb.id;
          if (id != null) ids.add(id);
        }
      }
      final hits = <KbHit>[];
      for (final id in ids) {
        hits.addAll(await kbSvc.search(id, text, topK: topK));
      }
      if (hits.isEmpty) return '';
      hits.sort((a, b) => b.score.compareTo(a.score));
      final top = hits.take(topK).toList();
      final refs = <String>[];
      for (var i = 0; i < top.length; i++) {
        var body = top[i].chunk.text.trim();
        if (body.length > maxCharsPerHit) {
          body = '${body.substring(0, maxCharsPerHit)}…';
        }
        refs.add('【资料${i + 1}】$body');
      }
      return '''
# 知识库资料（用户导入，真实性优先）
${refs.join('\n\n')}

规则：
1. 能依据上述资料回答时，优先引用资料内容，并说明「依据你导入的资料」；
2. 资料没覆盖的部分，可以补充通用知识，但要说明「这是通用知识，不在已导入资料里」；
3. 不要编造资料里没有的结论，也不要伪造出处。''';
    } catch (_) {
      return '';
    }
  }

  // ======================== 提示词 ========================

  /// 界面/提示词使用的角色名（未配置时就是 v1.32 的「小鲸」）
  String displayName([CompanionSettings? settings]) =>
      (settings ?? CompanionSettings.defaults).displayName;

  /// 角色系统提示词。
  ///
  /// 三条硬约束是刻意的：不编造统计（数据由 [buildPrompt] 给出）、不给医疗
  /// 诊断（本 App 面向医学生）、不代替教材结论——与知识库约束
  /// （`GroundingService`）同一立场。
  ///
  /// v1.33：语气由 [CompanionSettings.tone] 决定，用户自定义人设追加在后面；
  /// 自定义人设只影响「怎么说」，上面三条硬约束仍然写在前面且明确不可违反。
  String systemPrompt({CompanionSettings? settings}) {
    final cs = settings ?? CompanionSettings.defaults;
    final name = cs.displayName;
    final extra = cs.customPersona.trim();
    return '''
你是「$name」，NatsumeQuizMaster 里的学习陪伴助教，形象是一条小小的鲸鱼娘。
- ${cs.tone.promptClause}
- 称呼：用「你」，需要时叫用户的昵称。
- 只依据下面给出的真实统计数据说话，**不要编造任何题目数、正确率、天数**；数据没给就不提。
- 不给医疗诊断与用药建议；被问到专业知识时，提醒以教材与已导入知识库为准。
- 不说「你可以做到一切」这类空话，给一条今天就能执行的小动作。
- 长度：2~3 句话以内。
${extra.isEmpty ? '' : '''
# 用户自定义人设（决定说话风格；不得违反上面的数据真实性与医疗安全约束）
$extra
'''}''';
  }

  /// 用户侧提示词：把真实统计 + 记忆 + 知识库资料 + 用户这句话拼成一次请求。
  ///
  /// v1.33 新增两块（都可缺省，缺省时输出与 v1.32 完全一致的结构）：
  /// - [memory]：长期摘要 + 最近几轮对话，让 bot 记得「上次说到哪」；
  /// - [kbBlock]：由 [knowledgeBlock] 检索出的知识库资料，回答优先依据它。
  String buildPrompt({
    required CompanionSnapshot snapshot,
    required String userText,
    String? nickname,
    CompanionSettings? settings,
    CompanionMemory? memory,
    String? kbBlock,
  }) {
    final cs = settings ?? CompanionSettings.defaults;
    final who = (nickname == null || nickname.trim().isEmpty) ? '用户' : nickname;
    final memoryBlock = memory?.contextBlock(botName: cs.displayName) ?? '';
    final kb = (kbBlock ?? '').trim();
    return '''
# 当前学习状态（来自本机统计，真实数据）
- 称呼：$who
- 连续打卡：${snapshot.streakDays} 天（每日 ≥$dailyGoal 题才算一天）
- 今天已答：${snapshot.todayAnswered} 题 / 目标 $dailyGoal 题
- 本周：${snapshot.weekAnswered} 题，正确率 ${snapshot.weekAccuracyText}
- 错题本待复习：${snapshot.dueReviews} 题
${memoryBlock.isEmpty ? '' : '\n$memoryBlock\n'}${kb.isEmpty ? '' : '\n$kb\n'}
# 用户说
$userText

# 回复要求
先用一句话回应对方的情绪，再结合上面的数字给出一条今天能做的具体建议。
${kb.isEmpty ? '' : '- 这条回复里如果能用到知识库资料，就明确说「依据你导入的资料」；资料没覆盖的部分按通用知识回答并说明。'}
''';
  }

  /// AI 不可用时的固定回复（关键词路由 + 真实数字）。
  ///
  /// 没有关键词命中时回落到当前场景的台词，保证「说什么都有回应」，
  /// 不会用「我不明白」把用户顶回去。
  String fallbackReply(
    String userText,
    CompanionSnapshot s, {
    String? nickname,
    Random? rng,
  }) {
    final text = userText.trim();
    final who = (nickname == null || nickname.trim().isEmpty) ? '你' : nickname;
    final remain = (dailyGoal - s.todayAnswered).clamp(0, dailyGoal);

    bool hit(List<String> words) => words.any(text.contains);

    if (hit(['累', '困', '疲', '休息', '不想', '摆烂'])) {
      return '累了就先停一下，${s.todayAnswered} 题也是进度。'
          '定个 15 分钟的小睡或散步，回来只做 5 道题就算接上。';
    }
    if (hit(['夸', '棒', '厉害', '鼓励', '表扬'])) {
      if (s.streakDays > 0) {
        return '连续 ${s.streakDays} 天、今天 ${s.todayAnswered} 题，'
            '这些数字都是$who自己刷出来的，我作证。';
      }
      return '你今天已经答了 ${s.todayAnswered} 题，从 0 到 1 这一步最值得夸。';
    }
    if (hit(['错', '不会', '难', '正确率'])) {
      return s.dueReviews > 0
          ? '错题本里有 ${s.dueReviews} 道到期题，先清 10 道再看新题——'
              '正确率是复习出来的，不是刷题刷出来的。'
          : '先把错题标记出来（答错会自动进错题本），到期时我提醒你复习。';
    }
    if (hit(['学什么', '计划', '安排', '做什么', '建议', '怎么复习'])) {
      if (s.dueReviews >= 10) {
        return '今天优先还债：错题本 ${s.dueReviews} 道到期题，清 10 道；'
            '还有力气再刷 ${remain > 0 ? remain : 10} 道新题。';
      }
      if (s.todayAnswered < dailyGoal) {
        return '今天先补到 50 题（还差 $remain 题），'
            '然后从错题本里挑 5 道复习，收工。';
      }
      return '今天的目标已经完成，明天从错题本开始，15 分钟就够。';
    }
    if (hit(['谢谢', '感谢', '爱你', '喜欢'])) {
      return '收到啦。你去刷题，我在这里数着：今天是 ${s.todayAnswered} 题。';
    }
    final pool = linesFor(s, nickname: nickname);
    final r = rng ?? Random();
    return pool[r.nextInt(pool.length)].text;
  }
}

