import 'ai_service.dart';
import 'subject_keywords.dart';

/// 学科分类器抽象（轻量级方案，v13）。
///
/// 题目「自动分学科」的两条路径实现同一接口：
///   · [QwenSubjectClassifier] —— HTTP 调用通义等极速模型（优先）
///   · [KeywordSubjectClassifier] —— 本地关键词分类（备选，离线）
///
/// 未来如需更强的本地语义分类，可在同一接口下换成 TFLite 实现
/// （`tflite_flutter` + 一个文本分类模型），无需改调用方。
abstract class SubjectClassifier {
  Future<String?> classify(String text);
}

/// HTTP 通义等极速模型分类（优先）。
class QwenSubjectClassifier implements SubjectClassifier {
  QwenSubjectClassifier(this.ai);

  final AIService ai;

  @override
  Future<String?> classify(String text) => ai.classifySubjectFast(text);
}

/// 分学科服务：优先 HTTP，失败回退本地关键词。
class SubjectClassifierService {
  SubjectClassifierService(this.ai);

  final AIService ai;

  /// 分类一道题的内容，返回学科名；两条路径都判不出时返回 null。
  Future<String?> classify(String text) async {
    try {
      final http = await QwenSubjectClassifier(ai).classify(text);
      if (http != null && http.isNotEmpty) return http;
    } catch (_) {
      // 网络异常 → 回退本地
    }
    return KeywordSubjectClassifier.classifySync(text);
  }
}
