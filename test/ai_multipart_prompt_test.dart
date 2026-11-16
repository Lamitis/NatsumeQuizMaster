import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';

/// v1.42「AI 导入时多小问答案 / 解析必须逐问给出」的提示词契约。
///
/// 真实题库里大量「1）2）3）」小问，旧提示词只要求提取答案，模型常合成
/// 一段笼统结论。这里锁住三处：文本切题（DOCX/PDF/JSON）、视觉切题、
/// AI 补答案——任何一处漏掉这条约束都会让解析质量回退。
void main() {
  test('约束文案本身：强制逐问 + 禁止合并 + 给出示例格式', () {
    final rule = AIService.multiPartAnswerRule;
    expect(rule, contains('多个小问'));
    expect(rule, contains('correct_answer'));
    expect(rule, contains('analysis'));
    expect(rule, contains('逐一'));
    expect(rule, contains('绝不能合并'));
    expect(rule, contains('遗漏任何一问'));
    expect(rule, contains('答案：1. xxx；2. xxx'));
  });

  test('文本切题提示词（DOCX / PDF / JSON 导入）带上多小问约束', () {
    final prompt = AIService.buildImportPrompt('1）什么是休克？2）分期有哪些？');
    expect(prompt, contains(AIService.multiPartAnswerRule));
    expect(prompt, contains('14.'));
    // 原文知识点体系的口径没被这次改动破坏
    expect(prompt, contains('knowledge_point'));
    expect(prompt, contains('只返回 JSON'));
  });

  test('用户自定义知识点体系仍然生效（提示词重构零回归）', () {
    final prompt = AIService.buildImportPrompt(
      '题干',
      knowledgePointTypes: const ['呼吸系统', '循环系统'],
    );
    expect(prompt, contains('呼吸系统 / 循环系统'));
    expect(prompt, contains('只能从下列用户定义的知识点体系中选一个'));
  });

  test('AI 补答案提示词也要求按小问序号作答', () {
    final prompt = AIService.inferAnswersPrompt([
      Question(
        bankId: 1,
        title: '简述休克的治疗。1）一般处理 2）液体复苏 3）血管活性药',
        correctAnswer: '',
        questionType: 'jian_da',
        createdAt: '2026-01-01T00:00:00.000',
      ),
    ]);
    expect(prompt, contains('多个小问'));
    expect(prompt, contains('逐一'));
    expect(prompt, contains('绝不能合并'));
    // 原有「宁缺毋滥」约束还在
    expect(prompt, contains('拿不准的题不要出现在 answers 里'));
  });
}
