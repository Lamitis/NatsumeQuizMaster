import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/utils/format_utils.dart';

/// 「答完题自动切下一题」设置（v1.42）的纯逻辑契约：
/// ① 默认开启，老备份没有该键也按开启处理；
/// ② toMap / fromMap 往返保留关闭状态；
/// ③ 关闭后答题提示不再承诺「自动进入下一题」。
void main() {
  test('默认开启；老设置 / 老备份缺字段也按开启处理', () {
    expect(AppSettings().autoAdvanceAfterAnswer, isTrue);
    expect(AppSettings.fromMap(const {}).autoAdvanceAfterAnswer, isTrue);
    expect(
      AppSettings.fromMap(const {'auto_advance_after_answer': '1'})
          .autoAdvanceAfterAnswer,
      isTrue,
    );
  });

  test('toMap / fromMap 往返保留关闭状态', () {
    final settings = AppSettings().copyWith(autoAdvanceAfterAnswer: false);
    expect(settings.toMap()['auto_advance_after_answer'], '0');
    expect(
        AppSettings.fromMap(settings.toMap()).autoAdvanceAfterAnswer, isFalse);
  });

  test('copyWith 不传时保持原值', () {
    final off = AppSettings(autoAdvanceAfterAnswer: false);
    expect(off.copyWith(soundEnabled: false).autoAdvanceAfterAnswer, isFalse);
    expect(off.copyWith(autoAdvanceAfterAnswer: true).autoAdvanceAfterAnswer,
        isTrue);
  });

  test('关闭后答题提示不再承诺自动跳题', () {
    expect(answerHintText('single_choice'), contains('自动进入下一题'));
    expect(answerHintText('single_choice', autoAdvance: false),
        isNot(contains('自动进入下一题')));
    expect(answerHintText('single_choice', autoAdvance: false), contains('解析'));
    // 多选 / 填空的提示本来就与自动跳题无关，开关不应改动它们
    expect(answerHintText('multi_choice', autoAdvance: false),
        answerHintText('multi_choice'));
    expect(answerHintText('fill_blank', autoAdvance: false),
        answerHintText('fill_blank'));
  });
}
