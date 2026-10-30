import 'companion.dart';
import 'companion_settings.dart';

/// 一条被记住的对话（v1.33 记忆功能）。
///
/// 只存「谁说的 + 说了什么 + 哪天」，不存模型、耗时这些运维字段：
/// 记忆是给下一次对话喂上下文用的，不是审计日志。
class CompanionTurn {
  const CompanionTurn({
    required this.fromUser,
    required this.text,
    required this.day,
  });

  /// true = 用户说的；false = 小鲸说的
  final bool fromUser;

  final String text;

  /// 日期键 `yyyy-MM-dd`（跨天时提示词里可以带上「昨天说过」）
  final String day;

  String get role => fromUser ? 'user' : 'bot';

  Map<String, dynamic> toJson() =>
      {'role': role, 'text': text, 'day': day};

  /// 容错解析：字段缺失返回 null，由调用方过滤（脏行不该毁掉整段记忆）
  static CompanionTurn? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = (raw['text'] ?? '').toString().trim();
    if (text.isEmpty) return null;
    final role = (raw['role'] ?? 'user').toString();
    return CompanionTurn(
      fromUser: role != 'bot',
      text: text,
      day: (raw['day'] ?? '').toString(),
    );
  }
}

/// 陪伴对话的「记忆」（v1.33）。
///
/// 两层结构，避免为了「记得住」把整段历史每轮都塞进提示词：
/// - [turns]：最近 [maxTurns] 轮原文，喂给模型的是最后 [promptTurns] 轮；
/// - [summary]：**客观摘要**（连胜 / 今日题量 / 本周正确率 / 待复习），
///   每次落盘前用真实统计重算，等价于「长期记忆」——模型记不住的东西，
///   由本机统计替它记住，也就不会出现「记得你连了 30 天」这种幻觉。
///
/// 存储沿用 v1.32 的 settings 表一行 JSON（`companion_memory_v1`），
/// 不新建表、不涨 schema；容量上限是硬的（[maxTurns] × [maxTurnChars]），
/// 这样备份文件不会因为聊天记录无限膨胀。
class CompanionMemory {
  CompanionMemory({List<CompanionTurn>? turns, this.summary = ''})
      : turns = turns ?? <CompanionTurn>[];

  final List<CompanionTurn> turns;

  String summary;

  /// 最多保留多少轮（用户 + bot 各算一条）
  static const int maxTurns = 40;

  /// 每次请求带多少轮历史（太多会挤占输出预算）
  static const int promptTurns = 8;

  /// 单条消息落库上限：聊天不是日志，超长内容截断即可
  static const int maxTurnChars = 500;

  static CompanionMemory fresh() => CompanionMemory();

  bool get isEmpty => turns.isEmpty && summary.trim().isEmpty;

  int get length => turns.length;

  /// 记一条对话（自动截断 + 超上限裁剪）
  void add({
    required bool fromUser,
    required String text,
    DateTime? now,
  }) {
    final body = text.trim();
    if (body.isEmpty) return;
    turns.add(CompanionTurn(
      fromUser: fromUser,
      text: body.length > maxTurnChars
          ? '${body.substring(0, maxTurnChars)}…'
          : body,
      day: companionDayKey(now ?? DateTime.now()),
    ));
    _trim();
  }

  void _trim() {
    if (turns.length <= maxTurns) return;
    turns.removeRange(0, turns.length - maxTurns);
  }

  /// 用真实统计刷新长期摘要（每次落盘前调用，保持「记忆」不撒谎）
  void refreshSummary(CompanionSnapshot s, {String? nickname}) {
    final who = (nickname == null || nickname.trim().isEmpty)
        ? '用户'
        : nickname.trim();
    summary = '$who 的最近学习状态：连续打卡 ${s.streakDays} 天；'
        '今天已答 ${s.todayAnswered}/${CompanionSnapshot.dailyGoal} 题；'
        '本周 ${s.weekAnswered} 题、正确率 ${s.weekAccuracyText}；'
        '错题待到复习 ${s.dueReviews} 题。';
  }

  /// 拼进提示词的「历史记忆」块；没有任何内容时返回空串
  String contextBlock({
    String botName = CompanionSettings.defaultBotName,
    int last = promptTurns,
  }) {
    if (turns.isEmpty && summary.trim().isEmpty) return '';
    final buf = StringBuffer();
    if (summary.trim().isNotEmpty) {
      buf.writeln('# 长期记忆（本机统计，真实数据）');
      buf.writeln(summary.trim());
      buf.writeln();
    }
    if (turns.isNotEmpty) {
      final recent =
          turns.length <= last ? turns : turns.sublist(turns.length - last);
      buf.writeln('# 最近的对话（旧 → 新）');
      for (final t in recent) {
        buf.writeln('${t.fromUser ? '用户' : botName}：${t.text}');
      }
    }
    return buf.toString().trim();
  }

  void clear() {
    turns.clear();
    summary = '';
  }

  Map<String, dynamic> toJson() => {
        'summary': summary,
        'turns': [for (final t in turns) t.toJson()],
      };

  /// 容错解析：坏行跳过，整段坏掉就当没有记忆
  factory CompanionMemory.fromJson(Map<String, dynamic> json) {
    final rawTurns = json['turns'];
    final parsed = <CompanionTurn>[];
    if (rawTurns is List) {
      for (final raw in rawTurns) {
        final turn = CompanionTurn.tryFromJson(raw);
        if (turn != null) parsed.add(turn);
      }
    }
    final memory = CompanionMemory(
      turns: parsed,
      summary: (json['summary'] ?? '').toString().trim(),
    );
    memory._trim();
    return memory;
  }
}
