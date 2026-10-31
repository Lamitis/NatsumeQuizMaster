import 'question.dart';
import 'question_image.dart';

/// 题目编辑结果（v1.30.1）。
///
/// 此前 onSave 是 4 个位置参数（题干/答案/题型/配图），选项、解析、知识点
/// 旧编辑入口只能改题干和答案，选项/解析/知识点改不了。参数多了以后位置参数
/// 容易写反，改成结果对象一次带全。
///
/// v1.30.2：从 `widgets/question_edit_dialog.dart` 迁到 models 层。
/// 题库管理页要「按 id 改题」，落库逻辑在 `AppState` 里，而服务层不该
/// 反向 import 界面文件。
class QuestionEditResult {
  const QuestionEditResult({
    required this.title,
    required this.answer,
    required this.type,
    required this.images,
    required this.options,
    required this.analysis,
    required this.knowledgePoint,
  });

  final String title;
  final String answer;
  final String? type;
  final List<QuestionImage> images;
  final List<String> options;

  /// 空串表示「用户清空了解析」；null 不用（落库层 null 是「不更新」）
  final String analysis;

  /// 空串表示「用户清空了知识点」
  final String knowledgePoint;

  /// 按题目现状铺一份结果（题库管理「新建题目」以空壳起步时复用）
  factory QuestionEditResult.fromQuestion(Question q) => QuestionEditResult(
        title: q.title,
        answer: q.correctAnswer,
        type: q.questionType,
        images: q.images,
        options: q.options,
        analysis: q.analysis ?? '',
        knowledgePoint: q.knowledgePoint ?? '',
      );
}
