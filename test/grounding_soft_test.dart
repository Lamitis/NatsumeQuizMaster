import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/kb_chunk.dart';
import 'package:natsume_quiz_master/services/knowledge_base/grounding_service.dart';
import 'package:natsume_quiz_master/services/knowledge_base/kb_retriever.dart';

/// 知识库接地（v1.34）的**软约束**契约：
///
/// ① 资料优先但**不排他**——块里必须写明「没覆盖的部分可以用自己的知识补充」，
///    否则又回到「一本生理学知识库让病理题解析直接拒答」的老毛病；
/// ② 空命中返回空串 → 调用方跳过注入，解析与旧版完全一致（缓存照旧命中）；
/// ③ 单片超长截断、最多 [GroundingService.softMaxHits] 片，避免把整本教材塞进
///    提示词（既省钱也不淹没题目本身）。
void main() {
  KbHit hit(String text, {double score = 1.0}) => KbHit(
        KbChunk(
          docId: 1,
          kbId: 1,
          position: 0,
          text: text,
          createdAt: '2026-10-29',
        ),
        score,
      );

  test('软约束：资料优先，但允许 AI 用自身知识补全（不排他）', () {
    final block =
        GroundingService.buildSoftBlock([hit('动作电位的去极化由 Na⁺ 内流引起')]);

    expect(block, contains('【资料1】动作电位的去极化'));
    expect(block, contains('优先依据资料'));
    expect(block, contains('这是通用知识，不在已导入资料里'));
    // 硬约束那套「只允许依据资料」绝不能出现在软约束块里
    expect(block.contains('只允许依据这些资料'), isFalse);
  });

  test('无命中 → 空串（不注入，与旧版行为一致）', () {
    expect(GroundingService.buildSoftBlock(const []), '');
  });

  test('单片截断 + 条数上限', () {
    final long = 'x' * (GroundingService.softMaxCharsPerHit + 50);
    final block = GroundingService.buildSoftBlock([
      hit(long),
      hit('第二片'),
      hit('第三片'),
      hit('第四片'),
      hit('第五片'),
    ]);

    expect(block.contains('…'), isTrue, reason: '超长单片要截断');
    expect(block, contains('【资料4】'));
    expect(block.contains('【资料5】'), isFalse,
        reason: '最多注入 softMaxHits 片');
  });
}
