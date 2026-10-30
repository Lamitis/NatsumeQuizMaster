import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/utils/natsume_personality.dart';

/// 文案与元数据的纯逻辑测试：随机格言 / 加载语 / creator 标识。
void main() {
  group('随机格言 / 加载语', () {
    test('randomOf 用注入的 Random 确定性返回（同种子同结果）', () {
      final a = NatsumePersonality.randomOf(['a', 'b', 'c'], Random(42));
      final b = NatsumePersonality.randomOf(['a', 'b', 'c'], Random(42));
      expect(a, b);
    });

    test('randomMotto / randomLoading 都在各自候选池内', () {
      expect(NatsumePersonality.mottoes,
          contains(NatsumePersonality.randomMotto(Random(1))));
      expect(NatsumePersonality.loadingPhrases,
          contains(NatsumePersonality.randomLoading(Random(1))));
    });

    test('creator 标识非空', () {
      expect(NatsumePersonality.creatorMark, isNotEmpty);
    });

    test('加载语保持客观表述，不使用拟人化文案', () {
      for (final phrase in NatsumePersonality.loadingPhrases) {
        expect(phrase, isNot(contains('灵感')));
        expect(phrase, isNot(contains('请稍候...')),
            reason: '统一使用中文省略号');
      }
    });
  });
}
