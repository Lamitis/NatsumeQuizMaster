import 'kb_retriever.dart';

/// 知识库约束装配（v13 · 防幻觉）。
///
/// 把检索到的资料片段组装成一段「约束指令块」，注入 AI 解释 / 追问 /
/// 出题的提示词：AI 只允许依据给定资料作答，资料未覆盖则明确说不知道。
/// 这样用户导入的知识库就变成了答案的「边界」，而不是让模型自由发挥。
class GroundingService {
  const GroundingService._();

  /// 软约束模式下的单片资料上限（字符）
  static const int softMaxCharsPerHit = 700;

  /// 软约束模式下最多注入几片资料
  static const int softMaxHits = 4;

  /// 由命中结果拼装约束块；无命中返回空串（调用方可据此跳过注入）。
  static String buildBlock(List<KbHit> hits) {
    if (hits.isEmpty) return '';
    final refs = <String>[];
    for (var i = 0; i < hits.length; i++) {
      refs.add('【资料${i + 1}】${hits[i].chunk.text}');
    }
    return '''
# 知识库约束（最高优先级）
以下是用户导入的知识库资料片段，你的解释与答案**只允许依据这些资料**：

${refs.join('\n\n')}

规则：
1. 只依据上述资料作答，不得引入资料之外的主观推断或"常识"；
2. 若资料不足以回答，明确说明「该知识点在已导入资料中未提及」，不要强行作答；
3. 优先引用资料原话与数据，结论必须能在资料中找到依据。''';
  }

  /// **软约束**版本（v1.34）：资料是「参考资料」而不是「答案边界」。
  ///
  /// 用户原话：「将知识库接地接进解析，但并不是完全依赖知识库的解析，
  /// 不禁止 AI 本身的解析，因为知识库不一定全面」。
  ///
  /// 所以这里与 [buildBlock] 的硬约束有意不同：
  /// - 资料覆盖到的部分**优先**用资料，并标明「依据你导入的资料」；
  /// - 资料没覆盖的部分**允许**用模型自身知识补全，但必须声明是通用知识；
  /// - 两者冲突时以资料为准并指出冲突，绝不伪造出处。
  ///
  /// 好处是：导入一本生理学知识库不会让病理题解析直接拒答（硬约束的老毛病），
  /// 同时用户在自建资料里的结论仍然优先于模型的默认记忆。
  static String buildSoftBlock(
    List<KbHit> hits, {
    int maxCharsPerHit = softMaxCharsPerHit,
    int maxHits = softMaxHits,
  }) {
    if (hits.isEmpty) return '';
    final refs = <String>[];
    final limit = maxHits <= 0 ? hits.length : maxHits;
    for (var i = 0; i < hits.length && i < limit; i++) {
      var body = hits[i].chunk.text.trim();
      if (body.isEmpty) continue;
      if (body.length > maxCharsPerHit) {
        body = '${body.substring(0, maxCharsPerHit)}…';
      }
      refs.add('【资料${refs.length + 1}】$body');
    }
    if (refs.isEmpty) return '';
    return '''
# 知识库参考资料（用户导入，优先但不排他）
以下是用户导入的知识库片段，与本题相关度较高：

${refs.join('\n\n')}

规则：
1. 资料能覆盖的部分，优先依据资料，并说明「依据你导入的资料」；
2. 资料没覆盖的部分，**可以**用你自己的知识补全，但要说明「这是通用知识，不在已导入资料里」；
3. 两者说法不一致时，以资料为准并指出差异；
4. 不要编造资料里没有的结论，也不要伪造出处。''';
  }
}
