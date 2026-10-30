/// 学习陪伴插件（v1.32 · 「小鲸助教」）的模型层。
///
/// **取形来源**：Coopanion（`Pal-AI-Lab/Coopanion`，AGPL-3.0-or-later）的
/// 「好感度 / 情绪气泡 / 事件驱动」交互思路——它把桌宠做成一直接受事件
/// （答题、说话、时间）的常驻角色。本文件只搬这套**状态划分**，代码全部
/// 自行编写；界面也不是 Electron 桌宠，而是 Flutter 页面内的对话卡。
///
/// **素材边界（重要）**：Coopanion 的 `web/whale/` 鲸鱼娘贴图**不在其 AGPL
/// 授权范围内**（其 THIRD_PARTY_NOTICES 原文：「这些贴图不在本包的 AGPL
/// 授权范围内……想在别处使用请自行确认原设与各家标志的权利」，围裙上还
/// 带 DeepSeek / OpenAI 等商标图形）。因此本工程**不引用任何上游图像**，
/// 头像由 [CompanionAvatar] 用 CustomPainter 现场绘制，同样以 AGPL-3.0
/// 分发（见 THIRD_PARTY_NOTICES.md「Coopanion」一行）。
library;

/// 情绪档位：决定头像表情与气泡语气。
///
/// 与 Coopanion 的「表情包 vocab」思路一致：情绪是**有限枚举**而不是自由文
/// 本，这样脚本兜底与 AI 回复都能落到同一套表情，界面不需要解析文本。
enum CompanionMood {
  /// 平静：日常状态
  idle,

  /// 开心：有进展
  happy,

  /// 打气：正在努力但还没达到目标
  cheer,

  /// 担心：错题堆积 / 正确率偏低
  worried,

  /// 骄傲：达成当日目标
  proud,
}

extension CompanionMoodX on CompanionMood {
  /// 头像上的状态标签（对话页头部展示，测试也据此断言）
  String get label => switch (this) {
        CompanionMood.idle => '平静',
        CompanionMood.happy => '开心',
        CompanionMood.cheer => '打气',
        CompanionMood.worried => '担心',
        CompanionMood.proud => '骄傲',
      };
}

/// 场景：把「连续天数 / 今日题量 / 本周正确率 / 待复习」压成一个可判定、
/// 可测试的枚举，脚本文案与提示词都按场景取。
enum CompanionScene {
  /// 还没开始用（没有连胜、今天也没题）
  fresh,

  /// 今天还没开始，但有历史连胜
  idle,

  /// 今天在刷，还没到当日目标
  onTrack,

  /// 今天的 50 题目标达成
  goalReached,

  /// 本周正确率偏低（≥10 题样本才算）
  lowAccuracy,

  /// 待复习堆积（≥20 题到期）
  reviewBacklog,
}

/// 当前学习状态快照。
///
/// 数据全部来自本地既有统计（`AppState.getStreakDays` / `getDailyStats` /
/// `getPeriodStats` / `getErrorBookStats`），**不额外建表**：陪伴插件的
/// 私有状态只有好感度与最后互动日期，字段少到用 settings 一行 JSON 就够
/// （见 [CompanionState]），这样 DB schema 不需要从 v14 再涨一版。
class CompanionSnapshot {
  const CompanionSnapshot({
    required this.streakDays,
    required this.todayAnswered,
    required this.weekAnswered,
    required this.weekAccuracy,
    required this.dueReviews,
  });

  /// 连续打卡天数（≥50 题/天，假期冻结，与首页同口径）
  final int streakDays;

  /// 今天已答题数
  final int todayAnswered;

  /// 本周答题数（=0 时正确率没有意义，界面不展示百分比）
  final int weekAnswered;

  /// 本周正确率 0..100
  final double weekAccuracy;

  /// 错题本里已到期（含新卡）的题数
  final int dueReviews;

  /// 与「连续打卡」判定的每日门槛保持一致：50 题/天
  static const int dailyGoal = 50;

  /// 今日目标是否达成
  bool get reachedGoal => todayAnswered >= dailyGoal;

  /// 今天是否已经开刷
  bool get startedToday => todayAnswered > 0;

  /// 本周正确率的展示文案（无样本时给「—」而不是 0.0%）
  String get weekAccuracyText =>
      weekAnswered == 0 ? '—' : '${weekAccuracy.toStringAsFixed(1)}%';

  /// 场景判定（顺序即优先级：先把「该提醒的」判掉，再谈鼓励）。
  CompanionScene get scene {
    if (weekAnswered >= 10 && weekAccuracy < 60) {
      return CompanionScene.lowAccuracy;
    }
    if (dueReviews >= 20) return CompanionScene.reviewBacklog;
    if (!startedToday && streakDays == 0) return CompanionScene.fresh;
    if (!startedToday) return CompanionScene.idle;
    if (reachedGoal) return CompanionScene.goalReached;
    return CompanionScene.onTrack;
  }

  /// 空库 / 首启时的快照
  static const CompanionSnapshot empty = CompanionSnapshot(
    streakDays: 0,
    todayAnswered: 0,
    weekAnswered: 0,
    weekAccuracy: 0,
    dueReviews: 0,
  );
}

/// 一句台词 + 它对应的情绪。
class CompanionLine {
  const CompanionLine(this.text, this.mood);

  final String text;
  final CompanionMood mood;

  @override
  String toString() => 'CompanionLine($mood, $text)';
}

/// 陪伴状态（落 settings 表的一行 JSON）。
///
/// [affection] 是「好感度」：每聊一次 +1（每日首次额外 +2），上限
/// [maxAffection]；[lastDay] 记录最后互动日期，用来算「今天是否已见面」。
class CompanionState {
  const CompanionState({
    this.affection = 0,
    this.talks = 0,
    this.lastDay,
  });

  final int affection;
  final int talks;

  /// 最后互动日期（`yyyy-MM-dd`），null = 从没聊过
  final String? lastDay;

  static const int maxAffection = 999;

  static const CompanionState empty = CompanionState();

  CompanionState copyWith({int? affection, int? talks, String? lastDay}) =>
      CompanionState(
        affection: affection ?? this.affection,
        talks: talks ?? this.talks,
        lastDay: lastDay ?? this.lastDay,
      );

  Map<String, dynamic> toJson() => {
        'affection': affection,
        'talks': talks,
        if (lastDay != null) 'last_day': lastDay,
      };

  /// 容错解析：缺字段 / 脏数据一律回落 0，绝不让陪伴插件的坏状态
  /// 把整页打不开。
  factory CompanionState.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    final rawAffection = asInt(json['affection']);
    final rawTalks = asInt(json['talks']);
    final day = json['last_day']?.toString();
    return CompanionState(
      affection: rawAffection.clamp(0, maxAffection),
      talks: rawTalks < 0 ? 0 : rawTalks,
      lastDay: (day == null || day.isEmpty) ? null : day,
    );
  }
}

/// 日期键（本地时区），与 `DatabaseService._dateKey` 同格式
String companionDayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
