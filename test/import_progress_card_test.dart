import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/services/import_ocr_policy.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/import/import_progress_card.dart';

/// 导入进度卡（v1.41）：必须让用户一眼看出「现在在做什么、到哪一步」。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: ThemeService().themeData,
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(12), child: child)),
      );

  testWidgets('MinerU 阶段：显示页码文案、阶段徽章与百分比', (tester) async {
    await tester.pumpWidget(wrap(const ImportProgressCard(
      progress: 0.25,
      status: '正在使用 MinerU 识别第 3/12 页版面…',
    )));
    await tester.pump();

    expect(find.text('正在使用 MinerU 识别第 3/12 页版面…'), findsOneWidget);
    expect(find.text('MinerU 版面识别'), findsOneWidget);
    expect(find.text('25'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('普通路径：显示切块文案与阶段徽章', (tester) async {
    await tester.pumpWidget(wrap(const ImportProgressCard(
      progress: 0.6,
      status: ImportOcrPolicy.chunking,
    )));
    await tester.pump();

    expect(find.text(ImportOcrPolicy.chunking), findsOneWidget);
    expect(find.text('文本切块'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
  });

  testWidgets('阶段推断：检测文字层 / OCR / 视觉切题', (tester) async {
    expect(ImportProgressCard.phaseOf('正在检测 PDF 文字层（前 3 页）…'), '检测文字层');
    expect(ImportProgressCard.phaseOf('正在识别扫描页文字（2/5 页）…'), '端上 OCR');
    expect(ImportProgressCard.phaseOf('正在使用视觉模型切题（1/5 页）…'), '视觉切题');
    expect(ImportProgressCard.phaseOf('正在提取图文排版…'), '提取图文');
  });

  testWidgets('取消按钮只在给了 onCancel 时出现', (tester) async {
    await tester.pumpWidget(wrap(ImportProgressCard(
      progress: 0.1,
      status: ImportOcrPolicy.layoutExtracting,
      onCancel: () {},
    )));
    await tester.pump();
    expect(find.text('取消'), findsOneWidget);

    await tester.pumpWidget(wrap(const ImportProgressCard(
      progress: 0.1,
      status: ImportOcrPolicy.layoutExtracting,
    )));
    await tester.pump();
    expect(find.text('取消'), findsNothing);
  });
}
