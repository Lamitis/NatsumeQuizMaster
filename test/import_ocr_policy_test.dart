import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/services/import_ocr_policy.dart';
import 'package:natsume_quiz_master/services/pdf_import_service.dart';

/// 导入 OCR 策略（v1.41）：
///
/// 1. **只看前 2~3 页文字层**：平均每页 < 50 字或整片乱码 → 扫描件；
/// 2. **只有「桌面端 + 用户已开启 + 判定为扫描件」才触发 MinerU**，
///    移动端与电子版一律不白跑 OCR；
/// 3. 状态/降级文案固定，UI 与测试共用同一份常量。
void main() {
  group('扫描件判定（前 3 页抽样）', () {
    test('平均每页 < 50 字 → 扫描件', () {
      expect(
          ImportOcrPolicy.isScannedPdf(
              charCount: 149, sampledPages: 3, garbled: false),
          isTrue); // 49.6 字/页
    });

    test('平均每页 50 字 → 电子版（不触发 OCR）', () {
      expect(
          ImportOcrPolicy.isScannedPdf(
              charCount: 150, sampledPages: 3, garbled: false),
          isFalse);
    });

    test('一页 0 字 + 两页正常：平均仍够 → 不是扫描件', () {
      expect(
          ImportOcrPolicy.isScannedPdf(
              charCount: 400, sampledPages: 3, garbled: false),
          isFalse);
    });

    test('乱码即使字数很多也算扫描件', () {
      expect(
          ImportOcrPolicy.isScannedPdf(
              charCount: 3000, sampledPages: 3, garbled: true),
          isTrue);
    });

    test('抽样页数为 0（读不出页面）按扫描件处理', () {
      expect(
          ImportOcrPolicy.isScannedPdf(
              charCount: 0, sampledPages: 0, garbled: false),
          isTrue);
    });
  });

  group('MinerU 触发条件（仅 Windows 桌面端）', () {
    test('Windows + 已开启 + 扫描件 → 触发', () {
      expect(
          ImportOcrPolicy.shouldUseMineru(
              isWindows: true, enabled: true, needsOcr: true),
          isTrue);
    });

    test('移动端 → 永不触发（即使开启且是扫描件）', () {
      expect(
          ImportOcrPolicy.shouldUseMineru(
              isWindows: false, enabled: true, needsOcr: true),
          isFalse);
    });

    test('Windows 但用户未开启 → 不触发（上传第三方需明确同意）', () {
      expect(
          ImportOcrPolicy.shouldUseMineru(
              isWindows: true, enabled: false, needsOcr: true),
          isFalse);
    });

    test('电子版文字层正常 → 不触发（不再傻跑一遍 OCR）', () {
      expect(
          ImportOcrPolicy.shouldUseMineru(
              isWindows: true, enabled: true, needsOcr: false),
          isFalse);
    });
  });

  group('状态文案（需求原文）', () {
    test('MinerU 页码进度', () {
      expect(ImportOcrPolicy.mineruPage(3, 12),
          '正在使用 MinerU 识别第 3/12 页版面…');
    });

    test('MinerU 失败必须明确告知已回退', () {
      expect(ImportOcrPolicy.mineruFallback,
          'MinerU 版面识别失败，已回退至普通文本提取模式');
    });

    test('未触发 MinerU 的普通路径也要有状态', () {
      expect(ImportOcrPolicy.chunking, '正在切块解析题目…');
      expect(ImportOcrPolicy.layoutExtracting, '正在提取图文排版…');
      expect(ImportOcrPolicy.detectingTextLayer(), contains('前 3 页'));
    });

    test('移动端降级文案不出现「MinerU 失败」误导', () {
      expect(ImportOcrPolicy.mobileFallback, contains('移动端'));
      expect(ImportOcrPolicy.mobileFallback.contains('失败'), isFalse);
    });
  });

  group('乱码检测（文字层有字但读不懂）', () {
    test('正常中英文不是乱码', () {
      expect(PdfImportService.looksGarbled('第 1 题：下列哪项属于大分子？A. 蛋白质'),
          isFalse);
      expect(PdfImportService.looksGarbled('Question 1: which is correct?'),
          isFalse);
    });

    test('替换符（U+FFFD）占比高 → 乱码', () {
      expect(PdfImportService.looksGarbled('\uFFFD' * 10), isTrue);
    });

    test('私用区字符（U+E000–U+F8FF）占比高 → 乱码', () {
      expect(PdfImportService.looksGarbled('\uE000\uE001\uE002\uE003\uE004'),
          isTrue);
    });

    test('少量坏字符仍按正常文字处理（避免误伤）', () {
      final text = '${'正常题目内容' * 20}\uFFFD';
      expect(PdfImportService.looksGarbled(text), isFalse);
    });

    test('空字符串不是乱码（没文字层由字数判定）', () {
      expect(PdfImportService.looksGarbled(''), isFalse);
    });
  });
}
