import 'dart:async';

/// 打字机流式渲染缓冲（v1.40 · 小鲸助教）。
///
/// AI 接口本来就是流式的（每个 chunk 是**累计全文**），但 chunk 往往一次
/// 吐出十几个字，直接整段贴到气泡里就成了「一坨一坨地跳」。这里把到达的
/// 文字先堆进 [_pending]，再用 [Timer.periodic] 每 [tick] 放 [charsPerTick]
/// 个字——数据到达速度与显示速度解耦，观感是「一个字一个字蹦出来」。
///
/// 三条边界（对照需求逐条落实）：
/// 1. **以流式数据到达为基准**：只有 [feed] 收到新内容才会启动定时器，
///    流没来就绝不空转；
/// 2. **可中断**：关闭气泡 / 发送新消息 / 页面 dispose 时调用 [cancel]，
///    定时器立刻停、缓冲立刻丢，不会残留半个字或泄漏 Timer；
/// 3. **完成只回调一次**：[finish] 标记「流已结束」，等缓冲放完才回调
///    [onDrained]，调用方据此把「正在输入…」收掉。
class TypewriterBuffer {
  TypewriterBuffer({
    required this.onUpdate,
    this.onDrained,
    this.tick = const Duration(milliseconds: 24),
    this.charsPerTick = 2,
  })  : assert(charsPerTick > 0),
        assert(tick > Duration.zero);

  /// 每放出一批字回调一次（参数是「目前应该显示的全文」）
  final void Function(String visible) onUpdate;

  /// 流结束且缓冲放完时回调（只回调一次）
  final void Function()? onDrained;

  /// 两批字之间的间隔
  final Duration tick;

  /// 每批放几个字（中日韩字符一个就是一个字宽，2 个/24ms ≈ 83 字/秒）
  final int charsPerTick;

  Timer? _timer;

  /// 已到达但还没显示的字（保持到达顺序）
  String _pending = '';

  /// 已经显示出来的全文
  String _visible = '';

  /// 流是否已经结束（结束后缓冲放完就回调 [onDrained]）
  bool _finished = false;

  /// 已完成通知是否已经发出过（保证只回调一次）
  bool _notified = false;

  /// 当前应显示的文本（供 build 直接读）
  String get visible => _visible;

  /// 是否还有没放完的字
  bool get hasPending => _pending.isNotEmpty;

  /// 定时器是否在跑（测试/调试用）
  bool get isTicking => _timer != null;

  /// 追加一段**增量**文本。
  ///
  /// 注意：AI 流给的是累计全文，调用方要么自己算增量，要么用
  /// [feedCumulative]（内部按已收到的长度差量补齐）。
  void add(String chunk) {
    if (chunk.isEmpty) return;
    _pending += chunk;
    _ensureTimer();
  }

  /// 追加一段**累计全文**：只取比「已收到 + 待显示」多出来的部分。
  void feedCumulative(String full) {
    final received = _visible.length + _pending.length;
    if (full.length <= received) {
      // 少数服务商会在末尾补一个「修正版全文」：以更长的为准，短的不回退
      return;
    }
    add(full.substring(received));
  }

  /// 流结束：等缓冲放完就回调 [onDrained]（已经放完则立刻回调）。
  void finish() {
    _finished = true;
    if (_pending.isEmpty) _complete();
  }

  /// 立刻显示全部剩余内容（跳过打字机，仍只回调一次 [onDrained]）。
  void flushAll() {
    final rest = _pending;
    _pending = '';
    _visible += rest;
    if (rest.isNotEmpty) onUpdate(_visible);
    if (_finished) _complete();
  }

  /// 取消：停定时器、丢缓冲（关闭气泡 / 新消息 / dispose 用）。
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = '';
    _finished = false;
  }

  void _ensureTimer() {
    if (_timer != null || _pending.isEmpty) return;
    _timer = Timer.periodic(tick, (_) => _tick());
  }

  void _tick() {
    if (_pending.isEmpty) {
      // 流还没结束：停表等下一批 chunk（不空转）
      _stopTimer();
      if (_finished) _complete();
      return;
    }
    final take =
        _pending.length <= charsPerTick ? _pending.length : charsPerTick;
    _visible += _pending.substring(0, take);
    _pending = _pending.substring(take);
    onUpdate(_visible);
    if (_pending.isEmpty) {
      _stopTimer();
      if (_finished) _complete();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _complete() {
    _stopTimer();
    if (_notified) return;
    _notified = true;
    onDrained?.call();
  }
}
