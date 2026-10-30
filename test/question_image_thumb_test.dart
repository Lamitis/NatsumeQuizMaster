import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/question_image.dart';
import 'package:natsume_quiz_master/utils/design_tokens.dart';
import 'package:natsume_quiz_master/widgets/kit/natsume_rich_question_text.dart';
import 'package:natsume_quiz_master/widgets/question_image_viewer.dart';

/// 题干配图缩略尺寸（v1.34.1）：
///
/// 用户反馈「题目的图片框过大，一般合适在 3 行字 × 3 行字大小，点击后
/// 才是放大查看」。此前 `Image.memory(width: double.infinity)` 会把长图
/// 按整宽铺开，一道题被一张图顶到屏幕外。契约：
/// 1. 默认缩略图尺寸 = 3 行正文见方（与字号/行高同一来源，不写死像素）；
/// 2. 图片仍出现在占位符所在的阅读位置（不是外挂列表）；
/// 3. 点击缩略图才进全屏查看页。
void main() {
  // 1×1 真 PNG（能解码，避免落进 errorBuilder）
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

  QuestionImage tiny() => QuestionImage(
      position: 0,
      width: 1,
      height: 1,
      content: Uint8List.fromList(png));

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  test('缩略尺寸 = 3 行正文见方（跟随字号 token，不写死）', () {
    expect(kQuestionImageThumbSize,
        NatsumeType.body * NatsumeType.bodyHeight * 3);
    // 3 行字大小：比一行字大，但远小于整屏宽度（不做整宽铺图）
    expect(kQuestionImageThumbSize, greaterThan(NatsumeType.body * 2));
    expect(kQuestionImageThumbSize, lessThan(120));
  });

  testWidgets('题干配图默认是 3 行字见方的缩略图', (tester) async {
    await tester.pumpWidget(wrap(NatsumeRichQuestionText(
      text: '下图所示{{img:0}}最可能的诊断是',
      images: [tiny()],
    )));

    // 缩略图外框 = 3 行字见方（内层图片让开 1px 描边）
    final box = tester.getSize(find.byType(Hero));
    expect(box.width, kQuestionImageThumbSize);
    expect(box.height, kQuestionImageThumbSize);
    final image = tester.getSize(find.byType(Image));
    expect(image.width, kQuestionImageThumbSize - NatsumeLine.width * 2);
    expect(image.height, kQuestionImageThumbSize - NatsumeLine.width * 2);
    // 图文仍在同一内容流里
    expect(find.textContaining('下图所示'), findsOneWidget);
    expect(find.textContaining('最可能的诊断是'), findsOneWidget);
  });

  testWidgets('点击缩略图才进全屏放大页', (tester) async {
    await tester.pumpWidget(wrap(NatsumeRichQuestionText(
      text: '看图{{img:0}}作答',
      images: [tiny()],
    )));

    expect(find.byType(QuestionImageViewerPage), findsNothing);
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionImageViewerPage), findsOneWidget);
  });
}
