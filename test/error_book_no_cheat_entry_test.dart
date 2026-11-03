import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/models/answer_record.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/screens/error_book_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// 错题本 AppBar 的小抄入口（v1.40）。
///
/// v1.37 曾在宿主里硬编码一个「生成考前小抄」按钮，插件也带自己的小抄
/// 入口，装完插件就变成**两个按钮**。v1.40 把宿主入口彻底删掉，小抄统一
/// 交给插件 `ui_extensions`——未装插件时不该出现任何小抄入口。
///
/// 这个测试守的就是「删干净」：工具提示与图标都不能再出现，
/// 而管理 / 导出这两个宿主固定动作必须还在（别顺手删多了）。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_no_cheat_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> seedErrorQuestion() async {
    final db = DatabaseService.instance;
    final bankId = await db.insertBank(QuestionBank(
        name: '题库', createdAt: DateTime.now().toIso8601String()));
    await db.insertQuestions([
      Question(
        bankId: bankId,
        title: '病理题',
        options: const ['A项', 'B项'],
        correctAnswer: 'B',
        analysis: '肉芽组织由新生毛细血管和成纤维细胞组成。',
        knowledgePoint: '病理学',
        createdAt: DateTime.now().toIso8601String(),
      ),
    ]);
    final qid = (await db.getQuestionsByBank(bankId)).first.id!;
    await db.addToErrorBook(qid);
    await db.insertAnswerRecord(AnswerRecord(
      questionId: qid,
      userAnswer: 'A',
      isCorrect: false,
      answeredAt: DateTime.now().toIso8601String(),
    ));
  }

  Future<void> settleUntil(WidgetTester tester, Finder target,
      {required String what}) async {
    for (var i = 0; i < 60; i++) {
      if (target.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    fail('等待「$what」超时');
  }

  testWidgets('错题本不再有宿主硬编码的小抄按钮（交给插件接管）', (tester) async {
    tester.view.physicalSize = const Size(411, 891);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState appState;
    await tester.runAsync(() async {
      await seedErrorQuestion();
      appState = AppState();
      await appState.init();
      await appState.updateSettings(
          AppSettings(apiKey: 'sk-test', model: 'test-model'));
    });

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const MaterialApp(home: ErrorBookScreen()),
    ));
    await settleUntil(tester, find.byTooltip('管理错题'), what: '错题本骨架');

    expect(find.byTooltip('生成考前小抄'), findsNothing,
        reason: '宿主小抄入口已删除：装插件后不该出现两个按钮');
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing,
        reason: '小抄图标也不该残留');

    // 宿主固定动作还在：删除错题 / 导出错题
    expect(find.byTooltip('管理错题'), findsOneWidget);
    expect(find.byTooltip('导出错题'), findsOneWidget);
  });
}
