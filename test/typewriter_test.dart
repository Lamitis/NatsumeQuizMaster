import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/utils/typewriter.dart';

/// 打字机缓冲（v1.40 · 小鲸助教流式回复）。
///
/// 契约：
/// 1. **以数据到达为基准**：没有 chunk 就不启动定时器，不空转；
/// 2. 按 `charsPerTick` 逐批放出，chunk 累计全文不会重复显示；
/// 3. `finish()` 只在缓冲放完后回调一次 `onDrained`；
/// 4. `cancel()` 立刻停表清缓冲（关闭气泡 / 发送新消息 / dispose）。
void main() {
  testWidgets('按批放出：每 tick 出 charsPerTick 个字', (tester) async {
    var visible = '';
    final typer = TypewriterBuffer(
      tick: const Duration(milliseconds: 10),
      charsPerTick: 2,
      onUpdate: (v) => visible = v,
    );
    addTearDown(typer.cancel);

    typer.feedCumulative('你好世界');
    expect(visible, isEmpty, reason: '数据刚到不该立刻整段上屏');
    expect(typer.isTicking, isTrue);

    await tester.pump(const Duration(milliseconds: 10));
    expect(visible, '你好');

    await tester.pump(const Duration(milliseconds: 10));
    expect(visible, '你好世界');
    expect(typer.hasPending, isFalse, reason: '放完后应自动停表');
  });

  testWidgets('chunk 累计全文：只补差量，不重复显示', (tester) async {
    var visible = '';
    final typer = TypewriterBuffer(
      tick: const Duration(milliseconds: 10),
      charsPerTick: 2,
      onUpdate: (v) => visible = v,
    );
    addTearDown(typer.cancel);

    typer.feedCumulative('ab');
    typer.feedCumulative('abcd');
    // 第二个 chunk 是累计全文（ab + cd），不该把 ab 再塞一遍
    await tester.pump(const Duration(milliseconds: 10));
    expect(visible, 'ab');
    await tester.pump(const Duration(milliseconds: 10));
    expect(visible, 'abcd');
  });

  testWidgets('finish：缓冲放完才回调 onDrained，且只回调一次', (tester) async {
    var visible = '';
    var done = 0;
    final typer = TypewriterBuffer(
      tick: const Duration(milliseconds: 10),
      charsPerTick: 2,
      onUpdate: (v) => visible = v,
      onDrained: () => done++,
    );
    addTearDown(typer.cancel);

    typer.feedCumulative('abc');
    typer.finish();
    expect(done, 0, reason: '还有没放完的字，不该提前收「正在输入」');

    await tester.pump(const Duration(milliseconds: 10));
    expect(visible, 'ab');
    expect(done, 0);

    await tester.pump(const Duration(milliseconds: 10));
    expect(visible, 'abc');
    expect(done, 1);

    // 再 finish / 再 tick 都不该重复回调
    typer.finish();
    await tester.pump(const Duration(milliseconds: 50));
    expect(done, 1);
  });

  testWidgets('cancel：立刻停表并丢缓冲（关闭气泡 / 新消息）', (tester) async {
    var visible = '';
    var done = 0;
    final typer = TypewriterBuffer(
      tick: const Duration(milliseconds: 10),
      charsPerTick: 2,
      onUpdate: (v) => visible = v,
      onDrained: () => done++,
    );

    typer.feedCumulative('abcdef');
    typer.cancel();

    await tester.pump(const Duration(milliseconds: 100));
    expect(visible, isEmpty, reason: '取消后不该再蹦字');
    expect(typer.isTicking, isFalse);
    expect(typer.hasPending, isFalse);
    expect(done, 0, reason: '取消不等于完成，不该触发 onDrained');
  });
}
