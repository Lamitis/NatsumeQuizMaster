import 'dart:math';

/// NatsumeQuizMaster 的文案与元数据常量。
///
/// 集中管理加载提示、空状态格言与数据层 creator 标识，方便统一调整语气，
/// 也方便测试（随机数可注入）。
class NatsumePersonality {
  NatsumePersonality._();

  /// 数据层专属 creator 标识：静默写入知识库导出 / 世界打包的元数据。
  static const String creatorMark = "Natsume's Custom Build";

  /// AI 处理时的加载提示（AI 分学科 / 出题 / 解析时随机取一句）。
  ///
  /// 面向用户的文案保持客观、克制，不使用拟人化或玩笑化表达。
  static const List<String> loadingPhrases = [
    '正在检索知识库…',
    '正在整理相关知识点…',
    '正在生成结果，请稍候…',
    '正在校验内容依据…',
  ];

  /// 空状态 / 首页格言（中性、与学习相关的短句）。
  static const List<String> mottoes = [
    '日拱一卒，功不唐捐。',
    '温故而知新，可以为师矣。',
    '每一次练习都会留下记录。',
    '学习是一场与自己的长跑，慢一点也没关系。',
    '把不会的变成会的，就是最好的正反馈。',
  ];

  /// 从候选池随机取一条（可注入 [rng] 便于测试确定性）。
  static String randomOf(List<String> pool, [Random? rng]) {
    final r = rng ?? Random();
    return pool[r.nextInt(pool.length)];
  }

  static String randomLoading([Random? rng]) => randomOf(loadingPhrases, rng);

  static String randomMotto([Random? rng]) => randomOf(mottoes, rng);
}
