import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/services/knowledge_base/grounding_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_retriever.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('知识库约束装配（GroundingService）', () {
    test('无命中返回空串', () {
      expect(GroundingService.buildBlock(const []), isEmpty);
    });

    test('有命中时注入资料与约束规则', () {
      final hit = KbHit(
        KbChunk(
            docId: 1,
            kbId: 1,
            position: 0,
            text: '贫血指红细胞或血红蛋白低于正常。',
            createdAt: ''),
        1.0,
      );
      final block = GroundingService.buildBlock([hit]);
      expect(block, contains('贫血指红细胞或血红蛋白低于正常。'));
      expect(block, contains('只依据上述资料作答'));
      expect(block, contains('资料中未提及'));
    });
  });
}
