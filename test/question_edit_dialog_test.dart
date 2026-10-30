import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_edit.dart';
import 'package:natsume_quiz_master/widgets/question_edit_dialog.dart';

/// 题目编辑弹窗（v1.30.1）
///
/// 用户反馈：「题目编辑只能改题干和答案，选项、解析、知识点都改不了」。
/// 这里锁定三件事：① 选项可逐条编辑并回传；② 解析/知识点可编辑；
/// ③ 明显错误的编辑（答案超出选项范围）在保存前被拦下。
void main() {
  Question seed({String type = 'single_choice', List<String>? options}) =>
      Question(
        id: 1,
        bankId: 1,
        title: '缺铁性贫血最常见的原因是？',
        options: options ??
            const ['选项一内容', '选项二内容', '选项三内容', '选项四内容'],
        correctAnswer: 'A',
        analysis: '旧解析',
        questionType: type,
        knowledgePoint: '血液',
        createdAt: DateTime.now().toIso8601String(),
      );

  /// 打开弹窗，返回保存结果的读取器（保存发生在点击「保存」之后）
  Future<QuestionEditResult? Function()> openDialog(
      WidgetTester tester, Question q) async {
    QuestionEditResult? saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  QuestionEditDialog(question: q, onSave: (r) => saved = r),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return () => saved;
  }

  testWidgets('选项、解析、知识点都能编辑并回传', (tester) async {
    final read = await openDialog(tester, seed());

    // 4 个选项逐条渲染成输入框
    expect(find.text('A.'), findsOneWidget);
    expect(find.text('D.'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, '选项三内容'), '选项三（改）');
    await tester.enterText(find.widgetWithText(TextField, '血液'), '生化');
    await tester.enterText(find.widgetWithText(TextField, '旧解析'), '新解析');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = read();
    expect(saved, isNotNull);
    expect(saved!.options,
        ['选项一内容', '选项二内容', '选项三（改）', '选项四内容']);
    expect(saved.knowledgePoint, '生化');
    expect(saved.analysis, '新解析');
  });

  testWidgets('答案超出选项范围时拦截保存', (tester) async {
    final read = await openDialog(tester, seed());

    // 只有 4 个选项，答案给 F 属于必然无效的编辑
    await tester.enterText(find.widgetWithText(TextField, 'A'), 'F');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(read(), isNull, reason: '校验未通过时不应回调 onSave');
    expect(find.textContaining('超出选项范围'), findsOneWidget);
  });

  testWidgets('非选择题不展示选项编辑区，且保留原选项', (tester) async {
    final q = seed(type: 'true_false', options: const []);
    final read = await openDialog(tester, q);

    expect(find.text('添加选项'), findsNothing);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = read();
    expect(saved, isNotNull);
    expect(saved!.options, isEmpty); // 判断题不生成也不清空选项
    expect(saved.type, 'true_false');
  });
}
