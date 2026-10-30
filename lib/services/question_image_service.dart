import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/question_image.dart';
import '../utils/webp_encoder.dart';

/// 题目配图统一入口（v1.34）。
///
/// 所有进入题库的图片——PDF 抽出的图、用户从相册/文件夹加的图——都必须走
/// 这里：**统一转成 WebP**、长边限制在 [maxEdge]、体积压到 [maxBytes] 以内。
///
/// 为什么统一格式：题库里混着 JPEG/PNG/WebP 时，导出（DOCX/AI 视觉）与
/// 体积统计都要按格式分支；统一成 WebP 后「一张图 = 一段 WebP 字节」，
/// 体积也明显更小（无损 WebP 对截图/线图通常比 JPEG 小，且不失真）。
class QuestionImageService {
  QuestionImageService._();

  /// 长边上限（像素）
  static const int maxEdge = 1280;

  /// 单张体积上限（字节）
  static const int maxBytes = 512 * 1024;

  /// 统一产出的 MIME
  static const String mime = 'image/webp';

  /// 编码字节 → 配图。无法解码（脏数据/损坏）时返回 null，由调用方跳过。
  static QuestionImage? fromEncoded(
    Uint8List raw, {
    int position = 0,
    String? anchor,
  }) {
    if (raw.isEmpty) return null;
    img.Image? decoded;
    try {
      decoded = img.decodeImage(raw);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) return null;
    return fromImage(decoded, position: position, anchor: anchor);
  }

  /// 本地文件 → 配图（相册/文件选择器入口）。
  static Future<QuestionImage?> fromFile(
    String path, {
    int position = 0,
    String? anchor,
  }) async {
    try {
      final bytes = await File(path).readAsBytes();
      return fromEncoded(bytes, position: position, anchor: anchor);
    } catch (_) {
      return null;
    }
  }

  /// 已解码位图 → 配图（PDF 光栅化后直接走这条，免得再编一次码）。
  static QuestionImage? fromImage(
    img.Image source, {
    int position = 0,
    String? anchor,
  }) {
    if (source.width <= 0 || source.height <= 0) return null;
    var current = source;
    final longest = math.max(current.width, current.height);
    if (longest > maxEdge) {
      current = _resize(current, maxEdge / longest);
    }

    QuestionImage? best;
    for (var attempt = 0; attempt < 10; attempt++) {
      final encoded = _encode(current, position, anchor);
      if (encoded == null) break;
      if (best == null || encoded.content.length < best.content.length) {
        best = encoded;
      }
      if (encoded.content.length <= maxBytes) return encoded;

      final shortest = math.min(current.width, current.height);
      if (shortest <= 320) {
        // 图已经很小还超限：色深兜底（8→7→6→5），再不行就认了
        for (final bits in const [7, 6, 5]) {
          final quantized = _encode(_quantize(current, bits), position, anchor);
          if (quantized == null) break;
          if (quantized.content.length < best!.content.length) {
            best = quantized;
          }
          if (quantized.content.length <= maxBytes) return quantized;
        }
        break;
      }
      // 体积 ≈ 像素数：按超标比例估一个缩放（限幅避免一次缩太狠）
      final ratio = math.sqrt(maxBytes / encoded.content.length) * 0.95;
      final scale = ratio.clamp(0.45, 0.85).toDouble();
      current = _resize(current, scale);
    }
    // 死活压不进上限：返回目前最小的一版（有图总比丢图好，
    // 但绝不会把原始大图原样塞进库里）
    return best;
  }

  static QuestionImage? _encode(img.Image src, int position, String? anchor) {
    final bytes = WebpEncoder.encode(src.convert(numChannels: 4));
    if (bytes.isEmpty) return null;
    return QuestionImage(
      position: position,
      mime: mime,
      width: src.width,
      height: src.height,
      anchor: anchor,
      content: bytes,
    );
  }

  static img.Image _resize(img.Image src, double scale) {
    return img.copyResize(
      src,
      width: math.max(1, (src.width * scale).round()),
      height: math.max(1, (src.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }

  /// 通道量化到 [bits] 位（用于体积兜底：8→7→6→5）
  static img.Image _quantize(img.Image src, int bits) {
    final rgba =
        src.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
    final shift = 8 - bits;
    final out = Uint8List(rgba.length);
    for (var i = 0; i < rgba.length; i++) {
      out[i] = (rgba[i] >> shift) << shift;
    }
    return img.Image.fromBytes(
      width: src.width,
      height: src.height,
      bytes: out.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }

  /// 体积文案（编辑弹窗/导入预览给用户的提示用）
  static String sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()}KB';
    return '${bytes}B';
  }
}
