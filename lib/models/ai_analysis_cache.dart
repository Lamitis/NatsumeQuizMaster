/// 单题 AI 解析的持久化缓存行（v1.44）。
///
/// 为什么需要这个模型：v1.43 之前 `ai_cache` 只存一段文本，界面无法知道
/// 这条解析「是不是注入过知识库资料」「按哪一档详细程度生成的」。于是带知识库
/// 约束的解析干脆不写缓存（见 `AIService.streamAnalysis`），导入过知识库的
/// 用户每次进入题目都要重新请求一遍。
///
/// v1.44 起带约束的解析也落盘，并把**生成条件**一并记下来：
/// - [grounded]：生成时是否注入了知识库资料（界面打「依据知识库」标）；
/// - [detail]：生成时的回答详细程度档位（换档后旧文本照常显示，只是允许用户
///   手动重新生成）；
/// - [groundingSignature]：资料块指纹，知识库内容变化后据此提示「资料已更新」。
///
/// 关键取舍：这些元数据**只用于说明与提示**，不参与「要不要复用」的决策——
/// 复用一律优先命中缓存，只有用户手动点「重新生成解析」才会重新请求。
class AiAnalysisCache {
  const AiAnalysisCache({
    required this.questionId,
    required this.analysis,
    this.grounded = false,
    this.detail,
    this.groundingSignature,
    this.createdAt,
  });

  final int questionId;
  final String analysis;

  /// 生成时是否注入了知识库资料
  final bool grounded;

  /// 生成时的详细程度档位（`AnalysisDetail.name`；老数据为 null）
  final String? detail;

  /// 资料块指纹（无资料时为 null）
  final String? groundingSignature;

  /// 写入时间（ISO8601）
  final String? createdAt;

  @override
  String toString() =>
      'AiAnalysisCache(q=$questionId, grounded=$grounded, detail=$detail, '
      'chars=${analysis.length})';
}
