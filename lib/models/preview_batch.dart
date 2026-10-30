import 'question.dart';
import 'question_image.dart';

/// 一份文档的解析结果（**预览批次**）。
///
/// 批量导入（多选 DOCX/PDF）时每份文档各成一个题库，因此解析结果按文档
/// 分组成批次：当前正在看的那一份是「当前预览」，其余进预览队列排队。
/// 这样后一份解析完不会把前一份还没确认的结果顶掉——用户确认 / 放弃
/// 当前这份后自动接上下一个。
class PreviewBatch {
  const PreviewBatch({
    required this.bankName,
    required this.questions,
    this.orphans = const {},
    this.parseErrors = const [],
  });

  /// 题库名（文件名去扩展名，确认入库时再按重名规则加后缀）
  final String bankName;

  /// 解析出的题目（含 `{{img:N}}` 占位符）
  final List<Question> questions;

  /// 未归属配图（预览页手动指派）
  final Map<int, QuestionImage> orphans;

  /// 分块解析失败原因（预览页显性提示）
  final List<String> parseErrors;
}
