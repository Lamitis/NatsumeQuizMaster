import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/app_state.dart';

/// 「AI 补答案」（v1.34）的纯逻辑契约：
/// ① 提示词只给题干/选项/类型，并明确「拿不准就别给」；
/// ② 响应解析容错（围栏、截断、越界/空答案丢弃）；
/// ③ 答案规整成 App 认可的形式（选择只留合法字母、判断只留对/错）；
/// ④ 预览页只数缺答案的题，未配 AI 时补答案直接返回 0、不发请求。
void main() {
  Question q({
    String title = '题干',
    List<String> options = const [],
    String answer = '',
    String type = 'single_choice',
  }) =>
      Question(
        bankId: 1,
        title: title,
        options: options,
        correctAnswer: answer,
        questionType: type,
        createdAt: '2026-01-01T00:00:00.000',
      );

  final anemiaOptions = <String>[
    '缺铁性贫血',
    '巨幼细胞贫血',
    '再生障碍性贫血',
    '溶血性贫血',
  ];

  group('提示词（inferAnswersPrompt）', () {
    test('带题号、类型、选项字母，并要求宁缺毋滥', () {
      final prompt = AIService.inferAnswersPrompt([
        q(title: '缺铁性贫血的血象特点？', options: anemiaOptions),
        q(
          title: '肝硬化最常见的并发症是？',
          options: const ['上消化道出血', '肝性脑病'],
        ),
      ]);
      expect(prompt, contains('缺少标准答案'));
      expect(prompt, contains('拿不准的题不要出现在 answers 里'));
      expect(prompt, contains('[0] (single_choice) 缺铁性贫血的血象特点？'));
      expect(prompt, contains('[1] (single_choice) 肝硬化最常见的并发症是？'));
      expect(prompt, contains('A. 缺铁性贫血'));
      expect(prompt, contains('D. 溶血性贫血'));
      // 同一道题的选项写成一行，别让模型以为是不同题
      expect(prompt, contains('A. 上消化道出血  B. 肝性脑病'));
    });

    test('无选项的填空/名解题不写「选项：」行', () {
      final prompt = AIService.inferAnswersPrompt([
        q(title: '名词解释：休克', type: 'ming_jie'),
      ]);
      expect(prompt, contains('[0] (ming_jie) 名词解释：休克'));
      expect(prompt, isNot(contains('选项：')));
    });
  });

  group('响应解析（parseInferredAnswers）', () {
    test('标准响应：下标 → 答案', () {
      final parsed = AIService.parseInferredAnswers(
        '{"answers":[{"i":0,"a":"A"},{"i":2,"a":"对"}]}',
        3,
      );
      expect(parsed, {0: 'A', 2: '对'});
    });

    test('带 ```json 围栏也认', () {
      final parsed = AIService.parseInferredAnswers(
        '```json\n{"answers":[{"i":1,"a":"B"}]}\n```',
        2,
      );
      expect(parsed, {1: 'B'});
    });

    test('越界下标、空答案、非数字下标一律丢弃', () {
      final parsed = AIService.parseInferredAnswers(
        '{"answers":[{"i":0,"a":"A"},{"i":9,"a":"B"},{"i":-1,"a":"C"},'
        '{"i":1,"a":"  "},{"i":"x","a":"D"},{"i":1}]}',
        2,
      );
      expect(parsed, {0: 'A'});
    });

    test('截断的响应救回前部完整答案', () {
      final parsed = AIService.parseInferredAnswers(
        '{"answers":[{"i":0,"a":"A"},{"i":1,"a":"B"',
        2,
      );
      expect(parsed, {0: 'A'});
    });

    test('空串 / 非 JSON / 缺 answers 字段：返回空表不抛', () {
      expect(AIService.parseInferredAnswers('', 3), isEmpty);
      expect(AIService.parseInferredAnswers('抱歉，我无法完成', 3), isEmpty);
      expect(AIService.parseInferredAnswers('{"foo":[]}', 3), isEmpty);
      expect(AIService.parseInferredAnswers('{"answers":"A"}', 3), isEmpty);
    });
  });

  group('答案规整（normalizeInferredAnswer）', () {
    test('判断题：多种说法都收敛成对/错', () {
      final tf = q(type: 'true_false');
      for (final raw in ['对', '正确', '√', 'TRUE', 't']) {
        expect(AIService.normalizeInferredAnswer(tf, raw), '对', reason: raw);
      }
      for (final raw in ['错', '错误', '×', 'false', 'F']) {
        expect(AIService.normalizeInferredAnswer(tf, raw), '错', reason: raw);
      }
      expect(AIService.normalizeInferredAnswer(tf, '不确定'), '');
    });

    test('单选：字母、带前缀、越界字母', () {
      final single = q(options: anemiaOptions);
      expect(AIService.normalizeInferredAnswer(single, 'B'), 'B');
      expect(AIService.normalizeInferredAnswer(single, '答案是C'), 'C');
      expect(AIService.normalizeInferredAnswer(single, '答案是：D'), 'D');
      // 模型给了两个：单选只留第一个
      expect(AIService.normalizeInferredAnswer(single, 'A,C'), 'A');
      // 越界字母不算（只有 4 个选项）
      expect(AIService.normalizeInferredAnswer(single, 'Z'), '');
    });

    test('单选：模型抄了选项原文也能反推字母', () {
      final single = q(options: anemiaOptions);
      expect(AIService.normalizeInferredAnswer(single, '再生障碍性贫血'), 'C');
      expect(
        AIService.normalizeInferredAnswer(single, '答案：巨幼细胞贫血'),
        'B',
      );
    });

    test('多选：字母排序去重，抄原文按选项顺序', () {
      final multi = q(options: anemiaOptions, type: 'multi_choice');
      expect(AIService.normalizeInferredAnswer(multi, 'c,a'), 'A,C');
      expect(AIService.normalizeInferredAnswer(multi, 'A,A,B'), 'A,B');
      expect(
        AIService.normalizeInferredAnswer(multi, '溶血性贫血、缺铁性贫血'),
        'A,D',
      );
    });

    test('填空/名解/简答：去前缀去引号，超长截到 200 字', () {
      final blank = q(type: 'fill_blank');
      expect(
        AIService.normalizeInferredAnswer(blank, '  答案：幽门螺杆菌  '),
        '幽门螺杆菌',
      );
      expect(
        AIService.normalizeInferredAnswer(blank, 'Answer: Helicobacter'),
        'Helicobacter',
      );
      expect(AIService.normalizeInferredAnswer(blank, '「青霉素」'), '青霉素');
      expect(AIService.normalizeInferredAnswer(blank, '   '), '');
      final long = '甲' * 250;
      expect(AIService.normalizeInferredAnswer(blank, long).length, 200);
    });
  });

  group('预览页接入（AppState）', () {
    test('previewMissingAnswerCount 只数答案为空白的题', () {
      final state = AppState();
      state.setPreviewQuestionsForTest([
        q(answer: 'A'),
        q(answer: '  '),
        q(answer: ''),
        q(answer: '对', type: 'true_false'),
      ]);
      expect(state.previewMissingAnswerCount, 2);
    });

    test('未配置 AI：fillMissingPreviewAnswers 返回 0 且不动预览', () async {
      final state = AppState();
      state.setPreviewQuestionsForTest([
        q(title: '缺答案的题', options: anemiaOptions),
      ]);
      final filled = await state.fillMissingPreviewAnswers();
      expect(filled, 0);
      expect(state.previewQuestions.single.correctAnswer, '');
      expect(state.previewMissingAnswerCount, 1);
    });

    test('没有缺答案的题：返回 0（不发请求）', () async {
      final state = AppState();
      state.setPreviewQuestionsForTest([q(answer: 'B', options: anemiaOptions)]);
      expect(await state.fillMissingPreviewAnswers(), 0);
      expect(state.previewQuestions.single.correctAnswer, 'B');
    });
  });
}
