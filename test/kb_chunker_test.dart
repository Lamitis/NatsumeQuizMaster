import 'package:natsume_quiz_master/services/knowledge_base/kb_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('知识库切块（KbChunker）', () {
    test('短文本不切块', () {
      final chunks = KbChunker.splitText('这是一段很短的文本。');
      expect(chunks.length, 1);
      expect(chunks.first, '这是一段很短的文本。');
    });

    test('空文本返回空列表', () {
      expect(KbChunker.splitText(''), isEmpty);
      expect(KbChunker.splitText('   \n  '), isEmpty);
    });

    test('优先在换行边界切块', () {
      final text = List.generate(50, (i) => '第$i行内容，这是一行比较长的正文。').join('\n');
      final chunks = KbChunker.splitText(text, chunkSize: 200);
      expect(chunks.length, greaterThan(1));
      // 每块不超过 chunkSize
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(200));
      }
    });

    test('无分隔符时长文本硬切', () {
      final text = '字' * 2500;
      final chunks = KbChunker.splitText(text, chunkSize: 1000);
      expect(chunks.length, 3);
      for (final c in chunks) {
        expect(c.isNotEmpty, isTrue);
      }
    });

    test('单段超长时递归降级切分', () {
      // 一个超长段落（无换行），应能切分而不丢内容
      final text = '病理' * 1200;
      final chunks = KbChunker.splitText(text, chunkSize: 500);
      final total = chunks.fold<int>(0, (s, c) => s + c.length);
      expect(total, greaterThanOrEqualTo(text.length - chunks.length));
    });
  });
}
