import 'package:flutter/material.dart';

import '../screens/practice_screen.dart';
import '../screens/quiz_screen.dart';
import '../utils/app_constants.dart';
import 'app_state.dart';

/// 发起一轮答题的三种模式（自由选题面板 / 题库题号网格共用）。
///
/// 这三种模式的差异只在「抽题参数 + 落到哪个页面」：
/// - [quiz]     正常刷题：落库、答完即判、末题进小结；
/// - [practice] 练习：不落库，进 [PracticeEntryScreen] 选限时/不限时；
/// - [memorize] 背题：不落库、保持题库原序、只高亮正确选项。
///
/// 题库题号网格的模式选择与自由选题共用同一份代码：这些分支从
/// `quick_start_screen.dart` 抽到这里，两处只保留一次实现。
enum QuizLaunchMode { quiz, practice, memorize }

extension QuizLaunchModeX on QuizLaunchMode {
  /// 面板/筛选项上的短标签
  String get label => switch (this) {
        QuizLaunchMode.quiz => '正常刷题',
        QuizLaunchMode.practice => '练习',
        QuizLaunchMode.memorize => '背题模式',
      };

  /// 一句话说明（自由选题面板的模式单选行复用）
  String get description => switch (this) {
        QuizLaunchMode.quiz => '答完即判，立刻校对解析',
        QuizLaunchMode.practice => '答题卡模式，限时/不限时，统一批改',
        QuizLaunchMode.memorize => '直接展示答案，快速浏览记忆',
      };

  IconData get icon => switch (this) {
        QuizLaunchMode.quiz => Icons.flash_on_rounded,
        QuizLaunchMode.practice => Icons.edit_note_rounded,
        QuizLaunchMode.memorize => Icons.visibility_rounded,
      };

  /// 是否产生会话/作答记录（练习与背题零落库）
  bool get persistSession => this == QuizLaunchMode.quiz;
}

/// 发起答题的统一入口。
///
/// 调用方只需给出「模式 + 题库范围 + 题量 + 起始题号」，其余（假期拦截、
/// 抽题、空题库提示、跳转到目标页面）都在这里收口，避免开始页与题库页
/// 各写一份、日后改一处漏一处。
class QuizLauncher {
  const QuizLauncher._();

  /// 发起一轮答题。
  ///
  /// 返回 `null` 表示已经打开答题页；返回非空字符串是给用户看的原因
  /// （假期模式 / 未选题库 / 题库里没有题目），由调用方决定怎么提示。
  ///
  /// [bankIds] 显式给出题库范围：不写回 [AppState.selectedBankIds]，
  /// 因为题库题号网格只刷「当前这个库」，不应该悄悄改掉开始页的勾选状态。
  /// [startIndex] 从 0 开始，配合 [noShuffle] 才能保证「点第 N 个方块就
  /// 是第 N 题」——随机抽题时题号与方块对不上。
  ///
  /// [knowledgePoints] / [questionTypes] 为自由选题面板的可选筛选
  /// （空集合 = 不限，题号网格与背题等老入口都不传）。
  static Future<String?> launch(
    BuildContext context,
    AppState app, {
    required QuizLaunchMode mode,
    required Set<int> bankIds,
    int count = kQuestionCountAll,
    int startIndex = 0,
    bool noShuffle = false,
    Set<String> knowledgePoints = const <String>{},
    Set<String> questionTypes = const <String>{},
  }) async {
    if (app.vacationModeEnabled) return '寒暑假模式中，答题功能已暂停';
    if (bankIds.isEmpty) return '请先选择题库';

    // 跨 await 之后 context 不可再用，先把导航器取出来
    final nav = Navigator.of(context);

    final memorize = mode == QuizLaunchMode.memorize;
    if (memorize) app.noShuffle = true;
    try {
      await app.startQuizWithFilter(
        bankIds: bankIds,
        count: count,
        noShuffle: noShuffle || memorize,
        persistSession: mode.persistSession,
        knowledgePoints: knowledgePoints,
        questionTypes: questionTypes,
      );
    } finally {
      if (memorize) app.noShuffle = false;
    }

    if (app.quizQuestions.isEmpty) {
      // 筛到 0 题与「题库本来就没题」是两回事，提示要分开说清
      final filtered = knowledgePoints.isNotEmpty || questionTypes.isNotEmpty;
      return filtered ? '该条件下暂无题目，请调整筛选' : '所选题库中没有题目，请先导入题目';
    }

    // 起始题号夹取：题库题量可能在网格渲染后被改小（删题）
    if (startIndex > 0) {
      final target = startIndex.clamp(0, app.quizQuestions.length - 1);
      if (target > 0) app.jumpToQuestion(target);
    }

    switch (mode) {
      case QuizLaunchMode.quiz:
        await nav.push(
            MaterialPageRoute(builder: (_) => const QuizScreen()));
      case QuizLaunchMode.practice:
        await nav.push(
            MaterialPageRoute(builder: (_) => const PracticeEntryScreen()));
      case QuizLaunchMode.memorize:
        await nav.push(MaterialPageRoute(
            builder: (_) => const QuizScreen(quizMode: QuizMode.memorize)));
    }
    return null;
  }
}
