/// 本地学科关键词分类（轻量级方案备选，纯 Dart、离线、零依赖）。
///
/// 题目「自动分学科」的兜底路径：当 HTTP 调用通义等极速模型失败（断网/Key
/// 异常）时，用关键词命中数把题目归到最可能的学科。比 TFLite 更轻——不用
/// 带模型文件、不用原生库；若日后要更强的本地语义分类，可在同一接口下换
/// 成 TFLite 实现（见 `SubjectClassifierService`）。
class KeywordSubjectClassifier {
  KeywordSubjectClassifier._();

  /// 学科 → 特征关键词（命中越多越可能属于该学科）。
  static const Map<String, List<String>> subjectKeywords = {
    '解剖学': ['解剖', '动脉', '静脉', '神经', '骨骼', '肌肉', '器官', '毗邻', '体表', '结构', '韧带', '筋膜'],
    '生理学': ['生理', '机制', '调节', '反射', '电位', '渗透', '代谢', '激素', '兴奋', '抑制', '离子', '内环境'],
    '病理学': ['病理', '坏死', '炎症', '肿瘤', '癌', '梗死', '变性', '增生', '化生', '萎缩', '血栓', '栓塞'],
    '微生物学': ['微生物', '细菌', '病毒', '真菌', '螺旋体', '衣原体', '支原体', '立克次体', '芽胞', '革兰', '菌落'],
    '免疫学': ['免疫', '抗体', '抗原', '淋巴', 'T细胞', 'B细胞', '补体', '超敏', '自身免疫', '细胞因子', '吞噬'],
    '寄生虫学': ['寄生虫', '蛔虫', '绦虫', '吸虫', '原虫', '疟原虫', '血吸虫', '钩虫', '虫卵', '中间宿主'],
    '血液系统': ['贫血', '血液', '红细胞', '白细胞', '血小板', '骨髓', '凝血', '出血', '白血病', '血红蛋白', '溶血'],
  };

  /// 同步分类：返回命中数最多的学科名；无命中返回 null。
  static String? classifySync(String text) {
    if (text.trim().isEmpty) return null;
    final lower = text.toLowerCase();
    String? best;
    var bestScore = 0;
    for (final entry in subjectKeywords.entries) {
      var score = 0;
      for (final kw in entry.value) {
        if (lower.contains(kw.toLowerCase())) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = entry.key;
      }
    }
    return bestScore > 0 ? best : null;
  }
}
