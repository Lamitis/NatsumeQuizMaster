import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/services/subject_keywords.dart';

/// 本地学科关键词分类（轻量级方案备选路径）。
void main() {
  group('本地学科关键词分类（KeywordSubjectClassifier）', () {
    test('贫血/血红蛋白 → 血液系统', () {
      expect(
          KeywordSubjectClassifier.classifySync('患者出现贫血，血红蛋白降低，红细胞减少'),
          '血液系统');
    });

    test('细菌/革兰 → 微生物学', () {
      expect(KeywordSubjectClassifier.classifySync('革兰阳性菌，细菌培养结果'),
          '微生物学');
    });

    test('抗体/抗原/淋巴细胞 → 免疫学', () {
      expect(KeywordSubjectClassifier.classifySync('抗体与抗原结合，激活淋巴细胞'),
          '免疫学');
    });

    test('无医学关键词 → null（不硬凑学科）', () {
      expect(KeywordSubjectClassifier.classifySync('这是一道没有医学关键词的题目'), isNull);
      expect(KeywordSubjectClassifier.classifySync(''), isNull);
    });
  });
}
