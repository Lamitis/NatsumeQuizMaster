import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/models/question_image.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/question_image_service.dart';
import 'package:natsume_quiz_master/utils/webp_encoder.dart';

/// 题目配图 WebP 管线（v1.34）回归测试。
///
/// 关键风险在自研 VP8L 编码器：位流写错不会抛异常，只会「能存不能看」。
/// 因此这里一律用 `package:image` 的 WebPDecoder 解回来逐像素比对——
/// 编码器任何一处位序/Kraft 和出错都会被这条测试抓住。
void main() {
  img.Image gradient(int w, int h) {
    final out = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out.setPixelRgba(x, y, (x * 255 ~/ w), (y * 255 ~/ h),
            ((x + y) * 255 ~/ (w + h)), 255);
      }
    }
    return out;
  }

  void expectSamePixels(img.Image a, img.Image b) {
    expect(b.width, a.width, reason: '解码宽度应一致');
    expect(b.height, a.height, reason: '解码高度应一致');
    for (var y = 0; y < a.height; y++) {
      for (var x = 0; x < a.width; x++) {
        final pa = a.getPixel(x, y);
        final pb = b.getPixel(x, y);
        expect(
          [pb.r.toInt(), pb.g.toInt(), pb.b.toInt(), pb.a.toInt()],
          [pa.r.toInt(), pa.g.toInt(), pa.b.toInt(), pa.a.toInt()],
          reason: '($x,$y) 像素必须无损还原',
        );
      }
    }
  }

  group('VP8L 编码器（无损、可解码）', () {
    test('渐变图编出的确实是 WebP，且逐像素还原', () {
      final src = gradient(40, 24);
      final bytes = WebpEncoder.encode(src);
      expect(bytes.sublist(0, 4), [0x52, 0x49, 0x46, 0x46]); // RIFF
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
      expect(String.fromCharCodes(bytes.sublist(12, 16)), 'VP8L');
      final decoded = img.decodeImage(bytes);
      expect(decoded, isNotNull);
      expectSamePixels(src, decoded!);
    });

    test('纯色图（只有 1 个符号）与带 alpha 的图都能还原', () {
      final flat = img.Image(width: 17, height: 9, numChannels: 4);
      img.fill(flat, color: img.ColorRgba8(12, 200, 33, 255));
      expectSamePixels(flat, img.decodeImage(WebpEncoder.encode(flat))!);

      final alpha = img.Image(width: 9, height: 5, numChannels: 4);
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 9; x++) {
          alpha.setPixelRgba(x, y, x * 20, y * 40, 90, x * 25);
        }
      }
      final bytes = WebpEncoder.encode(alpha);
      expectSamePixels(alpha, img.decodeImage(bytes)!);
    });

    test('调色缓存开/关都能解码（两条路径都不许写坏位流）', () {
      final src = gradient(23, 13);
      expectSamePixels(src, img.decodeImage(WebpEncoder.encode(src))!);
      expectSamePixels(
          src, img.decodeImage(WebpEncoder.encode(src, colorCacheBits: 0))!);
    });

    test('1x1 与窄条这类边界尺寸不炸', () {
      final tiny = img.Image(width: 1, height: 1, numChannels: 4);
      tiny.setPixelRgba(0, 0, 7, 8, 9, 255);
      expectSamePixels(tiny, img.decodeImage(WebpEncoder.encode(tiny))!);

      final strip = gradient(1, 64);
      expectSamePixels(strip, img.decodeImage(WebpEncoder.encode(strip))!);
    });
  });

  group('配图服务（统一 WebP + 体积上限）', () {
    test('PNG 进来变成 WebP，元信息随之更新', () {
      final png = img.encodePng(gradient(80, 60));
      final out = QuestionImageService.fromEncoded(
          Uint8List.fromList(png),
          position: 2);
      expect(out, isNotNull);
      expect(out!.mime, 'image/webp');
      expect(out.position, 2);
      expect(out.width, 80);
      expect(out.height, 60);
      expect(out.content.length, lessThanOrEqualTo(QuestionImageService.maxBytes));
      expect(img.decodeImage(out.content), isNotNull);
    });

    test('超大图按长边缩小，且体积压进上限', () {
      final big = gradient(2400, 1600);
      final out = QuestionImageService.fromImage(big);
      expect(out, isNotNull);
      expect(math.max(out!.width, out.height),
          lessThanOrEqualTo(QuestionImageService.maxEdge));
      expect(out.content.length, lessThanOrEqualTo(QuestionImageService.maxBytes));
      expect(img.decodeImage(out.content), isNotNull);
    });

    test('无法解码的脏数据返回 null（存量配图转码要能跳过坏图）', () {
      expect(QuestionImageService.fromEncoded(Uint8List.fromList([1, 2, 3])),
          isNull);
      expect(QuestionImageService.fromEncoded(Uint8List(0)), isNull);
    });
  });

  group('存量配图统一转 WebP（启动后后台转码）', () {
    late Directory tmp;
    const now = '2026-10-29T00:00:00.000';

    setUp(() async {
      await DatabaseService.instance.close();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = Directory.systemTemp.createTempSync('natsume_webp_');
      DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
    });

    tearDown(() async {
      await DatabaseService.instance.close();
      DatabaseService.overrideDbPath = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('JPEG 配图就地转成 WebP；坏字节跳过且原样保留', () async {
      final db = DatabaseService.instance;
      final bankId = await db
          .insertBank(QuestionBank(name: 'T', createdAt: now));

      final jpegBytes = Uint8List.fromList(img.encodeJpg(
          img.fill(img.Image(width: 12, height: 8), color: img.ColorRgb8(9, 40, 90))));
      final ids = await db.insertQuestions([
        Question(
          bankId: bankId,
          title: '好图{{img:0}}',
          correctAnswer: 'A',
          createdAt: now,
          images: [
            QuestionImage(
              position: 0,
              width: 12,
              height: 8,
              mime: 'image/jpeg',
              content: jpegBytes,
            ),
          ],
        ),
        Question(
          bankId: bankId,
          title: '坏图{{img:0}}',
          correctAnswer: 'B',
          createdAt: now,
          images: [
            QuestionImage(
              position: 0,
              width: 1,
              height: 1,
              mime: 'image/jpeg',
              content: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ],
        ),
      ]);

      await AppState().normalizeLegacyQuestionImages();

      final map = await db.getImagesForQuestions(ids);
      final converted = map[ids[0]]!.single;
      expect(converted.mime, 'image/webp', reason: '存量配图应转成 WebP');
      expect(img.decodeImage(converted.content), isNotNull);
      expect(converted.width, 12);
      expect(converted.height, 8);

      final broken = map[ids[1]]!.single;
      expect(broken.content, [1, 2, 3, 4], reason: '解不开的坏图不能被清空');
      expect(broken.mime, 'image/jpeg');
    });
  });
}
