import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_retriever.dart';
import 'package:flutter_test/flutter_test.dart';

KbChunk _chunk(int i, String text) =>
    KbChunk(docId: 1, kbId: 1, position: i, text: text, createdAt: '');

void main() {
  group('知识库检索（BM25）', () {
    test('tokenize 中文按二元组切分', () {
      final tokens = KbRetriever.tokenize('细胞是基本单位');
      expect(tokens, contains('细胞'));
      expect(tokens, contains('胞是'));
    });

    test('tokenize 英文按词切分并小写', () {
      final tokens = KbRetriever.tokenize('Hello World 2024');
      expect(tokens, contains('hello'));
      expect(tokens, contains('world'));
      expect(tokens, contains('2024'));
    });

    test('检索能命中相关块', () {
      final retriever = KbRetriever()
        ..index([
          _chunk(0, '贫血是指血液中红细胞或血红蛋白含量低于正常值。'),
          _chunk(1, '肺炎链球菌是社区获得性肺炎最常见的病原体。'),
          _chunk(2, '高血压的诊断标准是收缩压大于等于140mmHg。'),
        ]);
      final hits = retriever.search('肺炎链球菌', topK: 2);
      expect(hits, isNotEmpty);
      expect(hits.first.chunk.text, contains('肺炎链球菌'));
    });

    test('空查询返回空', () {
      final retriever = KbRetriever()..index([_chunk(0, '内容')]);
      expect(retriever.search(''), isEmpty);
    });

    test('空索引返回空', () {
      final retriever = KbRetriever();
      expect(retriever.isEmpty, isTrue);
      expect(retriever.search('任何'), isEmpty);
    });
  });
}
