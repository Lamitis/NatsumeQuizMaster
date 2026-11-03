import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../models/question_image.dart';
import '../utils/pdf_layout.dart';
import 'ai_service.dart';
import 'debug_log_service.dart';
import 'import_ocr_policy.dart';
import 'question_image_service.dart';

/// PDF 抽取失败（[message] 可直接展示给用户）。
/// [scanned] = 判定为扫描件/图片字（无文字层）——这不是损坏，
/// 调用方可据此改走「视觉切题」通道而不是直接报错。
class PdfExtractException implements Exception {
  PdfExtractException(this.message, {this.scanned = false});
  final String message;
  final bool scanned;
  @override
  String toString() => message;
}

/// 抽取结果：可直接喂 AI 结构化的纯文本（图片以 `{{img:N}}` 占位符内嵌）
/// + 文档级图片池（全局槽位 → 图）。题内槽位重编在导入物化时做。
class PdfExtractResult {
  const PdfExtractResult({
    required this.rawText,
    required this.imagePool,
    required this.pageCount,
    required this.charCount,
  });

  final String rawText;

  /// 全局槽位（文档内 0 起）→ 图
  final Map<int, QuestionImage> imagePool;

  final int pageCount;
  final int charCount;
}

/// 前几页文字层抽样结果（v1.41）。
///
/// 只回答一个问题：**这份 PDF 需不需要 OCR**。字段保留页码与每页字数，
/// 便于日志/测试定位「为什么判成扫描件」，UI 不必展示。
class PdfTextLayerProbe {
  const PdfTextLayerProbe({
    required this.totalPages,
    required this.sampledPages,
    required this.charCount,
    required this.garbled,
    this.pageCharCounts = const [],
  });

  final int totalPages;

  /// 实际抽样的页数（文件不足 3 页时就是总页数）
  final int sampledPages;

  /// 抽样页里的有效字符数（去空白）
  final int charCount;

  /// 是否整片乱码（替换符 / 私用区 / 控制字符占比过高）
  final bool garbled;

  /// 每页字符数（诊断用）
  final List<int> pageCharCounts;

  double get charsPerPage => sampledPages <= 0 ? 0 : charCount / sampledPages;

  /// 是否需要 OCR：乱码 / 无文字层 / 平均每页字数低于阈值
  bool get needsOcr => ImportOcrPolicy.isScannedPdf(
        charCount: charCount,
        sampledPages: sampledPages,
        garbled: garbled,
      );
}

/// PDF 题库抽取：文本行按阅读序交织图区占位符，图区光栅化压缩进图片池。
///
/// 全本地、不依赖 AI：切题/题型仍走既有 AI 结构化链路，占位符随文本流过。
/// 图区检测走「行间空隙 + 取样有无墨迹」，位图/矢量/线图统一光栅化，
/// 避开「抽 PDF 嵌入图对象」在 Dart 生态没有成熟方案的问题。
class PdfImportService {
  /// 压缩上限：长边 ≤ [_maxImageEdge]、单张 ≤ [_maxImageBytes]
  /// （同时是局域网同步 64MB 单次快照的体积保护）
  static const int _maxImageEdge = 1280;
  static const int _maxImageBytes = 512 * 1024;

  /// 扫描页单页上限（比普通插图宽，理由见 [extractScannedPages]）
  static const int _maxScanPageBytes = 1024 * 1024;

  /// 无文字层判定：整册可抽字符低于此值视为扫描件/图片型 PDF
  static const int _minTextChars = 100;

  /// 抽样检测 PDF 前 [samplePages] 页的文字层（v1.41）。
  ///
  /// **只读文字层，不渲染、不抽图**——这一步要足够快（毫秒级），否则
  /// 「先判断再决定」本身就变成新的卡顿点。打开失败抛 [PdfExtractException]，
  /// 单页取字失败按 0 字计（不影响整份判断）。
  ///
  /// 判定口径见 [ImportOcrPolicy]：平均每页 < 50 字或整片乱码 → 扫描件。
  static Future<PdfTextLayerProbe> probeTextLayer(
    String filePath, {
    int samplePages = ImportOcrPolicy.samplePages,
  }) async {
    final PdfDocument doc;
    try {
      doc = await PdfDocument.openFile(filePath);
    } catch (_) {
      throw PdfExtractException('无法打开 PDF 文件（可能已加密或已损坏）');
    }
    try {
      final total = doc.pages.length;
      if (total == 0) {
        throw PdfExtractException('PDF 没有任何页面');
      }
      final take = math.min(math.max(1, samplePages), total);
      final counts = <int>[];
      final buffer = StringBuffer();
      for (var i = 0; i < take; i++) {
        var chars = 0;
        try {
          final text = await doc.pages[i].loadText();
          for (final f in text.fragments) {
            final value = f.text.trim();
            if (value.isEmpty) continue;
            chars += value.length;
            buffer.write(value);
          }
        } catch (_) {
          // 单页取不出文字：按 0 字算（扫描页本来就取不出）
        }
        counts.add(chars);
      }
      final charCount = counts.fold<int>(0, (sum, n) => sum + n);
      final probe = PdfTextLayerProbe(
        totalPages: total,
        sampledPages: take,
        charCount: charCount,
        garbled: looksGarbled(buffer.toString()),
        pageCharCounts: counts,
      );
      DebugLogService.instance.log(
        'PDF',
        '文字层抽样：${probe.sampledPages}/${probe.totalPages} 页，'
            '$charCount 字，乱码=${probe.garbled}，需OCR=${probe.needsOcr}',
      );
      return probe;
    } finally {
      await doc.dispose();
    }
  }

  /// 文字层是否「全是乱码」。
  ///
  /// 判据是**坏字符占比**：Unicode 替换符（U+FFFD，解码失败）、私用区
  /// （U+E000–U+F8FF，字体私有映射，常见于错误的 CJK 编码）与控制字符。
  /// 超过 20% 就认为「有字但读不懂」，应改走 OCR——这比按字数判断更贴近
  /// 用户看到的「一页火星文」。
  @visibleForTesting
  static bool looksGarbled(String text) {
    final value = text.trim();
    if (value.isEmpty) return false; // 空 = 没文字层，不是乱码
    final runes = value.runes.toList();
    var bad = 0;
    for (final r in runes) {
      if (r == 0xFFFD) {
        bad++;
      } else if (r >= 0xE000 && r <= 0xF8FF) {
        bad++;
      } else if (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) {
        bad++;
      }
    }
    return bad / runes.length > 0.2;
  }

  static Future<PdfExtractResult> extract(String filePath) async {
    final PdfDocument doc;
    try {
      doc = await PdfDocument.openFile(filePath);
    } catch (_) {
      throw PdfExtractException('无法打开 PDF 文件（可能已加密或已损坏）');
    }
    try {
      if (doc.pages.isEmpty) {
        throw PdfExtractException('PDF 没有任何页面');
      }
      final out = StringBuffer();
      final pool = <int, QuestionImage>{};
      var slot = 0;
      var charCount = 0;
      var seenQuestions = 0; // 已见题号行数（图归属期望题序用）

      for (final page in doc.pages) {
        final pageBox = (
          left: 0.0,
          top: page.height,
          right: page.width,
          bottom: 0.0,
        );

        var lines = <PdfTextLine>[];
        try {
          final text = await page.loadText();
          lines = groupTextLines([
            for (final f in text.fragments)
              PdfTextItem(
                f.text,
                (
                  left: f.bounds.left,
                  top: f.bounds.top,
                  right: f.bounds.right,
                  bottom: f.bounds.bottom,
                ),
              ),
          ]);
        } catch (_) {
          lines = const []; // 整页取不出文字：按整页候选处理
        }
        for (final l in lines) {
          charCount += l.text.trim().length;
        }

        // 行间空隙 → 取样判图 → 裁紧到墨迹范围
        // （不做相邻合并：被页脚/页码切开的整页图会各归各块，
        //  拆开显示好过猜错合并——两块通常同属一题，归属不受影响）
        final gaps = findGapCandidates(lines: lines, page: pageBox);
        final figures = <PdfBox>[];
        for (final gap in gaps) {
          final fig = await _detectFigure(page, gap.bounds, pageBox: pageBox);
          if (fig != null) figures.add(fig);
        }

        // 图文交织 + 图归属（「下图所示」原位 / 「上图所示」挂到下一题号前）
        final flow = assemblePageFlow(
          lines: lines,
          figures: figures,
          startsNewQuestion: AIService.isQuestionStart,
        );

        for (final item in flow) {
          if (item is PdfFlowTextItem) {
            out.writeln(item.line.text);
            if (AIService.isQuestionStart(item.line.text)) seenQuestions++;
          } else if (item is PdfFlowFigureItem) {
            // 期望题序：占位符都落在归属题号行之后，统一属当前题（seen-1）
            final ordinal = math.max(0, seenQuestions - 1);
            final image = await _renderFigure(
              page,
              item.bounds,
              pageBox: pageBox,
              slot: slot,
              expectedQuestion: ordinal,
            );
            if (image == null) continue;
            pool[slot] = image;
            out.writeln('{{img:${slot++}}}');
          }
        }
        out.writeln(); // 页间空行，防跨页两行粘连
      }

      if (charCount < _minTextChars) {
        // 扫描件/图片字：不是损坏，标记 scanned 让调用方改走视觉切题通道
        throw PdfExtractException(
            '该 PDF 没有文字层（扫描件/图片型），文字是画在图片里的。',
            scanned: true);
      }
      return PdfExtractResult(
        rawText: out.toString(),
        imagePool: pool,
        pageCount: doc.pages.length,
        charCount: charCount,
      );
    } finally {
      await doc.dispose();
    }
  }

  /// 扫描版 PDF → 逐页整页光栅化（JPEG），供视觉模型切题。
  ///
  /// 扫描页本身就是整页位图，渲染 1.5x 保证小字可读；编码上限放宽到
  /// 1MB/页（扫描页信息密度高，512KB 会糊字）。逐页回调 [onProgress]——
  /// 45 页全持内存约 20~40MB，调用方宜边取边用（当前导入是一次性流程，
  /// 可接受；将来流式化只需把返回值改 Stream）。
  static Future<List<Uint8List>> extractScannedPages(
    String filePath, {
    void Function(int done, int total)? onProgress,
  }) async {
    final PdfDocument doc;
    try {
      doc = await PdfDocument.openFile(filePath);
    } catch (_) {
      throw PdfExtractException('无法打开 PDF 文件（可能已加密或已损坏）');
    }
    try {
      final pages = <Uint8List>[];
      final total = doc.pages.length;
      for (var i = 0; i < total; i++) {
        final page = doc.pages[i];
        final fullWidth = math.max(1, (page.width * 1.5).round());
        final fullHeight = math.max(1, (page.height * 1.5).round());
        final rendered = await page.render(
          x: 0,
          y: 0,
          width: fullWidth,
          height: fullHeight,
          fullWidth: fullWidth.toDouble(),
          fullHeight: fullHeight.toDouble(),
        );
        if (rendered != null) {
          final raw = _decode(rendered);
          rendered.dispose();
          final enc = _encodeJpeg(raw, maxBytes: _maxScanPageBytes);
          if (enc.bytes.isNotEmpty) pages.add(enc.bytes);
        }
        onProgress?.call(i + 1, total);
      }
      return pages;
    } finally {
      await doc.dispose();
    }
  }

  /// 图区取样：低分辨率渲染空隙带，找墨迹包围盒（裁紧），过滤无图/线状噪声。
  /// 找不到真图返回 null。
  static Future<PdfBox?> _detectFigure(
    PdfPage page,
    PdfBox gap, {
    required PdfBox pageBox,
  }) async {
    if (boxHeight(gap) < 12) return null;
    final fullWidth = math.max(1, (boxWidth(pageBox) * 0.6).round());
    final fullHeight = math.max(1, (boxHeight(pageBox) * 0.6).round());
    final px = _clampPx(
        pdfBoxToPixels(gap, pageBox, fullWidth: fullWidth, fullHeight: fullHeight),
        fullWidth,
        fullHeight);
    final rendered = await page.render(
      x: px.x,
      y: px.y,
      width: px.width,
      height: px.height,
      fullWidth: fullWidth.toDouble(),
      fullHeight: fullHeight.toDouble(),
    );
    if (rendered == null) return null;
    final im = _decode(rendered);
    rendered.dispose();

    var minX = im.width, minY = im.height, maxX = -1, maxY = -1, ink = 0;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        if (p.r < 242 || p.g < 242 || p.b < 242) {
          ink++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (ink < 30 || maxX < 0) return null;

    // 内部墨迹校验：行间缝隙里只有文字边缘的抗锯齿辉光时，
    // 墨迹全贴在带边——要求去掉 4px 边框后仍有实墨，才认作图
    var innerInk = 0;
    for (var y = 4; y < im.height - 4; y++) {
      for (var x = 4; x < im.width - 4; x++) {
        final p = im.getPixel(x, y);
        if (p.r < 242 || p.g < 242 || p.b < 242) innerInk++;
      }
    }
    if (innerInk < 20) return null;

    // 墨迹包围盒（带 1px 松弛）回写 PDF 点
    final box = pixelsToPdfBox(
      px.x + minX - 1,
      px.y + minY - 1,
      maxX - minX + 3,
      maxY - minY + 3,
      pageBox,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
    final tight = (
      left: math.max(pageBox.left, box.left),
      top: math.min(pageBox.top, box.top),
      right: math.min(pageBox.right, box.right),
      bottom: math.max(pageBox.bottom, box.bottom),
    );
    // 最小尺寸过滤：横线/装订线等噪声不入图
    if (boxWidth(tight) < 24 || boxHeight(tight) < 16) return null;
    return tight;
  }

  /// 图区成品：2 倍分辨率光栅化 + JPEG 压缩（位图/矢量/线图一视同仁）
  static Future<QuestionImage?> _renderFigure(
    PdfPage page,
    PdfBox fig, {
    required PdfBox pageBox,
    required int slot,
    required int expectedQuestion,
  }) async {
    final fullWidth = math.max(1, (boxWidth(pageBox) * 2).round());
    final fullHeight = math.max(1, (boxHeight(pageBox) * 2).round());
    final px = _clampPx(
        pdfBoxToPixels(fig, pageBox, fullWidth: fullWidth, fullHeight: fullHeight),
        fullWidth,
        fullHeight);
    if (px.width < 4 || px.height < 4) return null;
    final rendered = await page.render(
      x: px.x,
      y: px.y,
      width: px.width,
      height: px.height,
      fullWidth: fullWidth.toDouble(),
      fullHeight: fullHeight.toDouble(),
    );
    if (rendered == null) return null;
    final raw = _decode(rendered);
    rendered.dispose();

    // v1.34：统一走配图服务 → WebP（长边 ≤1280、单张 ≤512KB）
    return QuestionImageService.fromImage(
      raw,
      position: slot,
      // anchor：页码:y 中心:期望题序（丢 token 抢修按期望题序补挂）
      anchor:
          '${page.pageNumber}:${((fig.top + fig.bottom) / 2).toStringAsFixed(1)}:$expectedQuestion',
    );
  }

  static ({int x, int y, int width, int height}) _clampPx(
    ({int x, int y, int width, int height}) px,
    int fullWidth,
    int fullHeight,
  ) {
    final x = math.max(0, math.min(px.x, fullWidth - 2));
    final y = math.max(0, math.min(px.y, fullHeight - 2));
    return (
      x: x,
      y: y,
      width: math.max(1, math.min(px.width, fullWidth - x)),
      height: math.max(1, math.min(px.height, fullHeight - y)),
    );
  }

  /// PDFium 像素（RGBA/BGRA）→ image 包位图
  static img.Image _decode(PdfImage pi) {
    final order = pi.format == ui.PixelFormat.bgra8888
        ? img.ChannelOrder.bgra
        : img.ChannelOrder.rgba;
    return img.Image.fromBytes(
      width: pi.width,
      height: pi.height,
      bytes: pi.pixels.buffer,
      bytesOffset: pi.pixels.offsetInBytes,
      order: order,
    );
  }

  /// JPEG 压缩到上限内：先限长边，超限再逐级缩边（保底 128px 不死磕）
  static ({Uint8List bytes, int width, int height}) _encodeJpeg(img.Image src,
      {int maxBytes = _maxImageBytes}) {
    var im = src;
    final edge = math.max(im.width, im.height);
    if (edge > _maxImageEdge) {
      final s = _maxImageEdge / edge;
      im = img.copyResize(im,
          width: math.max(1, (im.width * s).round()),
          height: math.max(1, (im.height * s).round()),
          interpolation: img.Interpolation.linear);
    }
    var bytes = Uint8List.fromList(img.encodeJpg(im, quality: 85));
    var w = im.width, h = im.height;
    while (bytes.length > maxBytes && (w > 128 || h > 128)) {
      im = img.copyResize(im,
          width: math.max(1, (w * 0.8).round()),
          height: math.max(1, (h * 0.8).round()),
          interpolation: img.Interpolation.linear);
      w = im.width;
      h = im.height;
      bytes = Uint8List.fromList(img.encodeJpg(im, quality: 75));
    }
    return (bytes: bytes, width: w, height: h);
  }
}
