import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 纯 Dart 的 **WebP 编码器**（VP8L 无损位流）。
///
/// 为什么要自己写：`package:image` 只有 WebP **解码器**（`webp_decoder.dart`），
/// 没有编码器；而 `flutter_image_compress` 这类原生插件不支持 Windows，本项
/// 目却要同时跑 Android 与 Windows。VP8L 是 WebP 的无损分支，只依赖位流与
/// 前缀码，纯 Dart 就能产出，任何平台都能解码（Flutter/Skia 原生支持）。
///
/// 编码策略（够用且可控）：
/// - 不写 transform、不写 meta-Huffman（单棵树覆盖全图）；
/// - 可选「调色缓存」（color cache）：同一像素重复出现只占 1 个符号，
///   截图/线图这类题目配图收益最大；
/// - 四个通道用规范 Huffman（码长 ≤15）压缩，码长表本身再用游程 +
///   19 符号的「码长码」压缩；
/// - 不做 LZ77 回溯引用（体积换实现复杂度；超限由上层降采样兜底）。
///
/// 正确性由单元测试用 `package:image` 的 WebPDecoder 解码回来逐像素比对。
class WebpEncoder {
  WebpEncoder._();

  static const int _numLiteralCodes = 256;
  static const int _numLengthCodes = 24;
  static const int _numDistanceCodes = 40;
  static const int _numCodeLengthCodes = 19;
  static const int _maxCodeLength = 15;

  /// 码长码（19 个符号）的码长只有 3 个 bit 可写，必须 ≤7
  static const int _maxCodeLengthCodeLength = 7;

  /// 码长码符号的书写顺序（VP8L 规范固定顺序，不是自然序）
  static const List<int> _codeLengthCodeOrder = [
    17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  ];

  /// 把 [image] 编码为 WebP 字节（RIFF 容器 + VP8L 位流）。
  ///
  /// [colorCacheBits]：调色缓存位数（0 = 关闭，1..11 有效）。
  static Uint8List encode(img.Image image, {int colorCacheBits = 10}) {
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
      return Uint8List(0);
    }
    final bits = colorCacheBits <= 0 ? 0 : math.min(colorCacheBits, 11);
    final cacheSize = bits == 0 ? 0 : 1 << bits;

    // 统一成 RGBA 再取字节：调色板/灰度/带 alpha 的输入都走同一条路径
    final rgba =
        image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);

    final pixelCount = width * height;
    final greenSymbols = Uint16List(pixelCount);
    final redSymbols = Uint8List(pixelCount);
    final blueSymbols = Uint8List(pixelCount);
    final alphaSymbols = Uint8List(pixelCount);
    final greenFreq = Int32List(_numLiteralCodes + _numLengthCodes + cacheSize);
    final redFreq = Int32List(_numLiteralCodes);
    final blueFreq = Int32List(_numLiteralCodes);
    final alphaFreq = Int32List(_numLiteralCodes);

    // 调色缓存：与解码端完全同构（argb * 0x1e35a7bd 取高位做 key）
    final cacheColor = cacheSize == 0 ? null : Int32List(cacheSize);
    final cacheUsed = cacheSize == 0 ? null : Uint8List(cacheSize);
    final cacheShift = 32 - bits;

    var hasAlpha = false;
    for (var i = 0; i < pixelCount; i++) {
      final o = i << 2;
      final r = rgba[o];
      final g = rgba[o + 1];
      final b = rgba[o + 2];
      final a = rgba[o + 3];
      if (a != 255) hasAlpha = true;

      if (cacheColor != null) {
        final argb = (a << 24) | (r << 16) | (g << 8) | b;
        final key = ((argb * 0x1e35a7bd) & 0xFFFFFFFF) >> cacheShift;
        if (cacheUsed![key] == 1 && cacheColor[key] == argb) {
          // 命中缓存：只写 1 个符号，红/蓝/alpha 都不写
          final symbol = _numLiteralCodes + _numLengthCodes + key;
          greenSymbols[i] = symbol;
          greenFreq[symbol]++;
          continue;
        }
        cacheUsed[key] = 1;
        cacheColor[key] = argb;
      }

      greenSymbols[i] = g;
      redSymbols[i] = r;
      blueSymbols[i] = b;
      alphaSymbols[i] = a;
      greenFreq[g]++;
      redFreq[r]++;
      blueFreq[b]++;
      alphaFreq[a]++;
    }
    final greenTree = _Huffman.build(greenFreq, _maxCodeLength);
    final redTree = _Huffman.build(redFreq, _maxCodeLength);
    final blueTree = _Huffman.build(blueFreq, _maxCodeLength);
    final alphaTree = _Huffman.build(alphaFreq, _maxCodeLength);
    // 无回溯引用 ⇒ 距离码从不使用，但仍必须给出一棵完整的（2 符号）树
    final distTree =
        _Huffman.build(Int32List(_numDistanceCodes), _maxCodeLength);

    final w = _BitWriter(math.max(64, pixelCount ~/ 2));
    w.writeBits(0x2F, 8); // VP8L 签名
    w.writeBits(width - 1, 14);
    w.writeBits(height - 1, 14);
    w.writeBits(hasAlpha ? 1 : 0, 1);
    w.writeBits(0, 3); // version
    w.writeBits(0, 1); // 无 transform（不写 predictor / subtract-green）
    w.writeBits(bits == 0 ? 0 : 1, 1);
    if (bits != 0) w.writeBits(bits, 4); // 调色缓存位数
    w.writeBits(0, 1); // 不用 meta-Huffman
    _writeHuffmanCode(w, greenTree.lengths);
    _writeHuffmanCode(w, redTree.lengths);
    _writeHuffmanCode(w, blueTree.lengths);
    _writeHuffmanCode(w, alphaTree.lengths);
    _writeHuffmanCode(w, distTree.lengths);

    // 像素数据：green → red → blue → alpha（命中缓存的像素只有 green）
    for (var i = 0; i < pixelCount; i++) {
      final gs = greenSymbols[i];
      w.writeBits(greenTree.revCodes[gs], greenTree.lengths[gs]);
      if (gs < _numLiteralCodes) {
        final rs = redSymbols[i];
        w.writeBits(redTree.revCodes[rs], redTree.lengths[rs]);
        final bs = blueSymbols[i];
        w.writeBits(blueTree.revCodes[bs], blueTree.lengths[bs]);
        final as = alphaSymbols[i];
        w.writeBits(alphaTree.revCodes[as], alphaTree.lengths[as]);
      }
    }

    return _wrapRiff(w.finish());
  }

  /// RIFF 容器：`RIFF <size> WEBP VP8L <chunkSize> <bitstream> [pad]`
  static Uint8List _wrapRiff(Uint8List stream) {
    final pad = stream.length.isOdd ? 1 : 0;
    final riffSize = 4 + 8 + stream.length + pad; // 'WEBP' + chunk 头 + 数据
    final out = Uint8List(8 + riffSize);
    out[0] = 0x52; // R
    out[1] = 0x49; // I
    out[2] = 0x46; // F
    out[3] = 0x46; // F
    _writeU32(out, 4, riffSize);
    out[8] = 0x57; // W
    out[9] = 0x45; // E
    out[10] = 0x42; // B
    out[11] = 0x50; // P
    out[12] = 0x56; // V
    out[13] = 0x50; // P
    out[14] = 0x38; // 8
    out[15] = 0x4C; // L
    _writeU32(out, 16, stream.length);
    out.setRange(20, 20 + stream.length, stream);
    return out;
  }

  static void _writeU32(Uint8List out, int offset, int value) {
    out[offset] = value & 0xFF;
    out[offset + 1] = (value >> 8) & 0xFF;
    out[offset + 2] = (value >> 16) & 0xFF;
    out[offset + 3] = (value >> 24) & 0xFF;
  }
  /// 写一棵前缀码：码长表用「码长码」+ 游程压缩后再写
  static void _writeHuffmanCode(_BitWriter w, Uint8List lengths) {
    final tokens = _rleLengths(lengths);
    final clFreq = Int32List(_numCodeLengthCodes);
    for (var i = 0; i < tokens.symbols.length; i++) {
      clFreq[tokens.symbols[i]]++;
    }
    final clTree = _Huffman.build(clFreq, _maxCodeLengthCodeLength);

    var numCodes = 4;
    for (var i = 0; i < _codeLengthCodeOrder.length; i++) {
      if (clTree.lengths[_codeLengthCodeOrder[i]] != 0) numCodes = i + 1;
    }
    if (numCodes < 4) numCodes = 4;

    w.writeBits(0, 1); // 0 = 非 simple code（走码长表）
    w.writeBits(numCodes - 4, 4);
    for (var i = 0; i < numCodes; i++) {
      w.writeBits(clTree.lengths[_codeLengthCodeOrder[i]], 3);
    }
    w.writeBits(0, 1); // 不写 use_length：码长覆盖整个字母表
    for (var i = 0; i < tokens.symbols.length; i++) {
      final sym = tokens.symbols[i];
      w.writeBits(clTree.revCodes[sym], clTree.lengths[sym]);
      final extraBits = tokens.extraBits[i];
      if (extraBits > 0) w.writeBits(tokens.extras[i], extraBits);
    }
  }

  /// 码长数组 → 「码长码」符号 + 附加位（0 游程用 17/18，避免逐位写 0）
  static _Tokens _rleLengths(Uint8List lengths) {
    final symbols = <int>[];
    final extras = <int>[];
    final extraBits = <int>[];
    var i = 0;
    while (i < lengths.length) {
      final v = lengths[i];
      if (v != 0) {
        symbols.add(v);
        extras.add(0);
        extraBits.add(0);
        i++;
        continue;
      }
      var run = 0;
      while (i + run < lengths.length && lengths[i + run] == 0 && run < 138) {
        run++;
      }
      i += run;
      while (run >= 11) {
        final take = math.min(run, 138);
        symbols.add(18);
        extras.add(take - 11);
        extraBits.add(7);
        run -= take;
      }
      while (run >= 3) {
        final take = math.min(run, 10);
        symbols.add(17);
        extras.add(take - 3);
        extraBits.add(3);
        run -= take;
      }
      while (run > 0) {
        symbols.add(0);
        extras.add(0);
        extraBits.add(0);
        run--;
      }
    }
    return _Tokens(symbols, extras, extraBits);
  }
}

class _Tokens {
  final List<int> symbols;
  final List<int> extras;
  final List<int> extraBits;
  const _Tokens(this.symbols, this.extras, this.extraBits);
}

/// LSB-first 位写入器（VP8L 位流的字节内顺序）
class _BitWriter {
  _BitWriter(int initialBytes)
      : _buf = Uint8List(initialBytes < 64 ? 64 : initialBytes);

  Uint8List _buf;
  int _len = 0;
  int _bits = 0;
  int _count = 0;

  void writeBits(int value, int count) {
    if (count == 0) return;
    _bits |= (value & ((1 << count) - 1)) << _count;
    _count += count;
    while (_count >= 8) {
      _emit(_bits & 0xFF);
      _bits >>= 8;
      _count -= 8;
    }
  }

  void _emit(int byte) {
    if (_len == _buf.length) {
      final grown = Uint8List(_buf.length * 2);
      grown.setRange(0, _len, _buf);
      _buf = grown;
    }
    _buf[_len++] = byte;
  }

  Uint8List finish() {
    if (_count > 0) {
      _emit(_bits & 0xFF);
      _bits = 0;
      _count = 0;
    }
    return Uint8List.sublistView(_buf, 0, _len);
  }
}
/// 规范 Huffman 码长求解（码长上限 + Kraft 修正 + 兜底等长码）
class _Huffman {
  final Uint8List lengths;
  final Uint16List revCodes;

  const _Huffman._(this.lengths, this.revCodes);

  static _Huffman build(Int32List freqs, int maxLen) {
    final n = freqs.length;
    final lengths = Uint8List(n);
    if (n == 0) return _Huffman._(lengths, Uint16List(0));
    if (n == 1) {
      lengths[0] = 1;
      return _Huffman._(lengths, Uint16List(1));
    }

    final used = <int>[];
    for (var i = 0; i < n; i++) {
      if (freqs[i] > 0) used.add(i);
    }
    if (used.isEmpty) {
      // 一个符号都没用到：造一个合法的最小完整码（0/1 各 1 位）
      lengths[0] = 1;
      lengths[1] = 1;
      return _Huffman._(lengths, _codesFromLengths(lengths));
    }
    if (used.length == 1) {
      // 前缀码至少要两个叶子才「完整」，补一个空符号占位
      used.add(used.first == 0 ? 1 : 0);
    }

    // 普通 Huffman：小顶堆合并频率最低的两棵子树
    final heap = _NodeHeap();
    for (final s in used) {
      heap.push(_HuffNode(freqs[s], s));
    }
    while (heap.length > 1) {
      final a = heap.pop();
      final b = heap.pop();
      heap.push(_HuffNode(a.freq + b.freq, -1, a, b));
    }
    final depths = <int, int>{};
    void walk(_HuffNode node, int depth) {
      if (node.symbol >= 0) {
        depths[node.symbol] = depth == 0 ? 1 : depth;
        return;
      }
      walk(node.left!, depth + 1);
      walk(node.right!, depth + 1);
    }

    walk(heap.pop(), 0);

    used.sort();
    final lens = <int>[for (final s in used) math.min(depths[s]!, maxLen)];
    final freqList = <int>[for (final s in used) freqs[s]];
    if (!_limitLengths(lens, freqList, maxLen)) {
      _assignBalancedLengths(lens, freqList, maxLen);
    }
    for (var i = 0; i < used.length; i++) {
      lengths[used[i]] = lens[i];
    }
    return _Huffman._(lengths, _codesFromLengths(lengths));
  }
  /// 把码长压到 [maxLen] 内并让 Kraft 和恰好等于 1（否则解码端判为不完整码）。
  /// 返回 false 表示修正没收敛，调用方应退到等长码。
  static bool _limitLengths(List<int> lens, List<int> freqs, int maxLen) {
    final target = 1 << maxLen;
    var kraft = 0;
    for (final l in lens) {
      kraft += 1 << (maxLen - l);
    }
    var guard = 0;
    while (kraft > target) {
      if (guard++ > 200000) return false;
      // 加长频率最小的符号（对体积影响最小）
      var best = -1;
      for (var i = 0; i < lens.length; i++) {
        if (lens[i] >= maxLen) continue;
        if (best < 0 || freqs[i] < freqs[best]) best = i;
      }
      if (best < 0) return false;
      kraft -= 1 << (maxLen - lens[best] - 1);
      lens[best] += 1;
    }
    while (kraft < target) {
      if (guard++ > 200000) return false;
      final deficit = target - kraft;
      var best = -1;
      var bestDelta = 0;
      for (var i = 0; i < lens.length; i++) {
        if (lens[i] <= 1) continue;
        final delta = 1 << (maxLen - lens[i]);
        if (delta > deficit) continue;
        if (best < 0 || freqs[i] > freqs[best]) {
          best = i;
          bestDelta = delta;
        }
      }
      if (best < 0) return false;
      kraft += bestDelta;
      lens[best] -= 1;
    }
    return kraft == target;
  }

  /// 兜底：等长码（`count` 个符号里挑 `2^L - count` 个用 L-1 位，Kraft 恰好为 1）
  static void _assignBalancedLengths(
      List<int> lens, List<int> freqs, int maxLen) {
    final count = lens.length;
    var l = 0;
    while ((1 << l) < count) {
      l++;
    }
    if (l > maxLen) l = maxLen;
    final shortCount = math.max(0, (1 << l) - count);
    final order = List<int>.generate(count, (i) => i)
      ..sort((a, b) => freqs[b].compareTo(freqs[a]));
    for (var i = 0; i < count; i++) {
      lens[i] = l;
    }
    for (var i = 0; i < shortCount && i < count; i++) {
      lens[order[i]] = l - 1 < 1 ? 1 : l - 1;
    }
    // 校验一次 Kraft：不恰好等于 1 就整体退回等长码（宁可多花位，不能写坏码）
    var kraft = 0;
    for (final len in lens) {
      kraft += 1 << (maxLen - len);
    }
    if (kraft != 1 << maxLen) {
      for (var i = 0; i < count; i++) {
        lens[i] = l;
      }
    }
  }

  /// 规范码表：按 (码长, 符号) 顺序分配，位序按 VP8L 要求反转
  static Uint16List _codesFromLengths(Uint8List lengths) {
    final rev = Uint16List(lengths.length);
    var maxLen = 0;
    for (final l in lengths) {
      if (l > maxLen) maxLen = l;
    }
    if (maxLen == 0) return rev;
    final hist = Int32List(maxLen + 1);
    for (final l in lengths) {
      if (l > 0) hist[l]++;
    }
    final nextCodes = Int32List(maxLen + 1);
    var code = 0;
    for (var len = 1; len <= maxLen; len++) {
      code = (code + hist[len - 1]) << 1;
      nextCodes[len] = code;
    }
    for (var s = 0; s < lengths.length; s++) {
      final len = lengths[s];
      if (len == 0) continue;
      final c = nextCodes[len]++;
      var r = 0;
      for (var i = 0; i < len; i++) {
        r = (r << 1) | ((c >> i) & 1);
      }
      rev[s] = r;
    }
    return rev;
  }
}

class _HuffNode {
  final int freq;
  final int symbol;
  final _HuffNode? left;
  final _HuffNode? right;
  const _HuffNode(this.freq, this.symbol, [this.left, this.right]);
}

/// 建树用的最小堆（alphabet ≤ 2336，简单二叉堆足够）
class _NodeHeap {
  final List<_HuffNode> _items = [];

  int get length => _items.length;

  void push(_HuffNode node) {
    _items.add(node);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_items[parent].freq <= _items[i].freq) break;
      final tmp = _items[parent];
      _items[parent] = _items[i];
      _items[i] = tmp;
      i = parent;
    }
  }

  _HuffNode pop() {
    final top = _items.first;
    final last = _items.removeLast();
    if (_items.isEmpty) return top;
    _items[0] = last;
    var i = 0;
    while (true) {
      final l = (i << 1) + 1;
      final r = l + 1;
      var smallest = i;
      if (l < _items.length && _items[l].freq < _items[smallest].freq) {
        smallest = l;
      }
      if (r < _items.length && _items[r].freq < _items[smallest].freq) {
        smallest = r;
      }
      if (smallest == i) break;
      final tmp = _items[i];
      _items[i] = _items[smallest];
      _items[smallest] = tmp;
      i = smallest;
    }
    return top;
  }
}
