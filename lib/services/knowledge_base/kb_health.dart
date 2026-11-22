import 'kb_retriever.dart';

/// 知识库检索健康度报告（v1.44）。
///
/// 起因是「已经加了向量搜索，但它到底靠不靠得住？」——这句话没法用「应该没问题」
/// 回答，只能把可测的量摆出来：库里有几篇文档、切成几块、多少块有向量、
/// 向量覆盖率多少、一次检索花多久、同一句查询在两条检索路径下各命中什么。
///
/// 设计取舍：**只报事实 + 给出可执行的建议**，不做「自动调参」。检索质量取决于
/// 用户自己的资料，程序无法替他判断「这条资料该不该被检索到」；能做的是把
/// 覆盖率、耗时、命中来源摊开，让用户/开发者自己看见问题在哪。
class KbHealthReport {
  const KbHealthReport({
    required this.kbId,
    required this.documentCount,
    required this.chunkCount,
    required this.embeddedChunkCount,
    required this.vectorEnabled,
    required this.embeddingModel,
    required this.averageChunkChars,
    required this.emptyDocCount,
    this.probeQuery,
    this.probeMilliseconds,
    this.hybridHits = const [],
    this.plainHits = const [],
  });

  final int kbId;
  final int documentCount;
  final int chunkCount;

  /// 已有向量的块数（按当前模型的 storageKey 统计）
  final int embeddedChunkCount;

  /// 向量检索是否真的可用（开关 + Key + 供应商支持 Embeddings）
  final bool vectorEnabled;
  final String embeddingModel;

  /// 平均块长（字符）。过大 → 检索粒度粗；过小 → 语义碎片化
  final double averageChunkChars;

  /// 正文为空的文档数（导入失败/几乎没解析出东西的迹象）
  final int emptyDocCount;

  /// 下面三项只有做过「试检索」才有值
  final String? probeQuery;
  final int? probeMilliseconds;
  final List<KbHit> hybridHits;
  final List<KbHit> plainHits;

  /// 向量覆盖率 0~1（没有块时为 0）
  double get embeddingCoverage =>
      chunkCount == 0 ? 0 : embeddedChunkCount / chunkCount;

  bool get hasAnyVector => embeddedChunkCount > 0;

  /// 混合检索里「靠语义命中」的条数（诊断用）
  int get hybridVectorMatched =>
      hybridHits.where((h) => h.matchedByVector).length;

  /// 混合检索里「靠关键词命中」的条数（诊断用）
  int get hybridKeywordMatched =>
      hybridHits.where((h) => h.matchedByKeyword).length;

  /// 可执行的改进建议（按严重程度排序，空列表 = 未发现明显问题）。
  ///
  /// 每条都必须是用户能动手做的一件事，不写「建议优化检索质量」这种空话。
  List<String> get advice {
    final out = <String>[];
    if (documentCount == 0) {
      out.add('这个知识库里还没有文档，检索必然为空——先去导入资料。');
      return out;
    }
    if (chunkCount == 0) {
      out.add('文档没有切出任何文本块：很可能是扫描件或空文件，重新导入并确认能读到正文。');
    }
    if (emptyDocCount > 0) {
      out.add('有 $emptyDocCount 篇文档正文为空，占用列表但检索不到内容，建议删除或重新导入。');
    }
    if (!vectorEnabled) {
      out.add('未启用向量检索：当前只做关键词（逐字）匹配，'
          '换个说法问就检索不到。设置 → AI 接口里开启「知识库向量检索」并填 Embedding 模型。');
    } else if (!hasAnyVector) {
      out.add('已开启向量检索但还没有任何向量：请等待后台补齐，'
          '或在设置里切换一次 Embedding 模型以触发重建。');
    } else if (embeddingCoverage < 0.95) {
      out.add('向量覆盖率只有 ${(embeddingCoverage * 100).toStringAsFixed(0)}%：'
          '没覆盖到的块只能靠关键词命中，建议在设置里重新触发一次向量补齐。');
    }
    if (averageChunkChars > 900) {
      out.add('平均块长 ${averageChunkChars.toStringAsFixed(0)} 字偏大，'
          '一段资料塞进多个知识点时检索会不精确；拆分文档或删掉无关章节效果更明显。');
    }
    if (averageChunkChars > 0 && averageChunkChars < 120) {
      out.add('平均块长 ${averageChunkChars.toStringAsFixed(0)} 字偏小，'
          '资料被切得太碎，答案容易断章取义；建议按章节整理后再导入。');
    }
    if (probeQuery != null && hybridHits.isEmpty) {
      out.add('试检索没有命中任何资料：确认这个关键词确实出现在资料里，或换一个更具体的说法。');
    }
    if (out.isEmpty) {
      out.add('未发现明显问题：文档切块、向量覆盖率与检索延迟都在正常范围。');
    }
    return out;
  }

  KbHealthReport copyWith({
    String? probeQuery,
    int? probeMilliseconds,
    List<KbHit>? hybridHits,
    List<KbHit>? plainHits,
  }) =>
      KbHealthReport(
        kbId: kbId,
        documentCount: documentCount,
        chunkCount: chunkCount,
        embeddedChunkCount: embeddedChunkCount,
        vectorEnabled: vectorEnabled,
        embeddingModel: embeddingModel,
        averageChunkChars: averageChunkChars,
        emptyDocCount: emptyDocCount,
        probeQuery: probeQuery ?? this.probeQuery,
        probeMilliseconds: probeMilliseconds ?? this.probeMilliseconds,
        hybridHits: hybridHits ?? this.hybridHits,
        plainHits: plainHits ?? this.plainHits,
      );
}
