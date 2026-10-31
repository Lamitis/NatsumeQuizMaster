import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/screens/settings_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/sync/lan_address.dart';
import 'package:natsume_quiz_master/services/sync/sync_discovery.dart';
import 'package:natsume_quiz_master/services/sync/sync_engine.dart';
import 'package:natsume_quiz_master/services/sync/sync_models.dart';
import 'package:natsume_quiz_master/services/sync/sync_pair_payload.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

class FakeSettingsState extends AppState {
  AppSettings current = AppSettings(autoSync: false);
  bool reminder = false;
  DateTime? time;
  @override
  AppSettings get settings => current;
  @override
  Future<void> updateSettings(AppSettings settings) async {
    current = settings;
    notifyListeners();
  }

  @override
  bool get reminderEnabled => reminder;
  @override
  DateTime? get reminderTime => time;
  @override
  Future<void> setReminderSettings(
      {required bool enabled, DateTime? time}) async {
    reminder = enabled;
    this.time = time ?? this.time;
    notifyListeners();
  }

  @override
  Future<double?> fetchAIBalance() async => null;
  @override
  Future<int> getUntaggedErrorCount() async => 0;
}

class FailingSync extends ChangeNotifier implements SyncEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  bool get syncing => false;
  @override
  String get statusMessage => '';
  @override
  DateTime? get lastSyncAt => null;
  @override
  List<DiscoveredPeer> get peers => [];
  bool running = false;
  bool fail = true;
  @override
  bool get started => running;
  @override
  Future<void> start({required bool autoSync}) async {
    if (fail) throw StateError('service unavailable');
    running = true;
  }

  @override
  Future<void> applyAutoSync(bool enabled) async {
    if (fail && enabled) throw StateError('apply unavailable');
  }

  // ── 识别码与同步范围（2026-10-08 新增的 SyncEngine API）──
  // mock 必须显式实现，否则 noSuchMethod 抛错会让整个同步区块渲染失败
  @override
  String get deviceCode => 'TESTCODE0000AAAA';
  @override
  String get peerCode => '';
  @override
  bool get paired => false;
  @override
  String get tempCode => '';
  @override
  DateTime? get tempExpiry => null;
  @override
  bool get tempCodeAlive => false;
  @override
  bool get banksOnly => false;
  @override
  void applyPeerCode(String raw, {bool autoVerify = true}) {}
  @override
  void generateTempCode() {}
  @override
  void clearTempCode() {}
  @override
  void applyBanksOnly(bool banksOnly) {}

  // ── 配对状态机与网络诊断（2026-10-30 新增的 SyncEngine API）──
  // 设置页无条件读取这些 getter（配对状态行 + 「网络诊断」标题摘要），
  // 若不显式实现，noSuchMethod 会抛错使整个同步区块渲染失败。
  @override
  SyncPairState get pairState => SyncPairState.none;
  @override
  String get pairDetail => '';
  @override
  String get confirmedPeerName => '';
  @override
  Future<void> verifyPairing() async {}
  @override
  int get httpPort => 0;
  @override
  SyncDiscoveryStats get discoveryStats => const SyncDiscoveryStats(
        sent: 0,
        sendFailures: 0,
        received: 0,
        ignored: 0,
        lastSentAt: null,
        lastReceivedAt: null,
        lastError: null,
        boundPort: 0,
        heals: 0,
        interfaces: <String>[],
      );
  @override
  Future<List<LanInterface>> localInterfaces() async => const <LanInterface>[];
  @override
  Future<SyncPairPayload> buildPairPayload() async =>
      const SyncPairPayload(code: 'TESTCODE0000AAAA');
  @override
  Future<bool> pairFromScan(SyncPairPayload payload) async => false;
}

class FakeReminderActions extends SettingsReminderActions {
  bool granted = false;
  bool failSchedule = false;
  int schedules = 0;
  @override
  Future<bool> hasPermission() async => granted;
  @override
  Future<bool> requestPermission() async => granted;
  @override
  Future<void> syncSchedule() async {
    schedules++;
    if (failSchedule) throw StateError('schedule unavailable');
  }
}

void main() {
  Future<void> showSettings(WidgetTester tester, FakeSettingsState app,
      FailingSync sync, FakeReminderActions reminder,
      {SettingsGroup group = SettingsGroup.sync}) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<SyncEngine>.value(value: sync),
        ChangeNotifierProvider<ThemeService>(create: (_) => ThemeService()),
      ],
      child: MaterialApp(
          home: SettingsScreen(
        group: group,
        reminderActions: reminder,
      )),
    ));
    await tester.pumpAndSettle();
  }

  // ── 分组索引表回归 ──────────────────────────────────────────
  // SettingsGroup.indices 是「按 sections 下标取块」的脆弱写法：改 sections
  // 顺序就必须同步改表。2026-10-29 吃过一次亏——在 AI 组插入 MinerU 卡片后
  // 没同步索引，「同步与提醒」组里的每日提醒整块消失（渲染成 0 个 widget），
  // 而页面本身不报错、只是少一块，很难发现。这里给每组钉标志性标题。
  const groupMarkers = <SettingsGroup, List<String>>{
    SettingsGroup.ai: ['AI 接口配置', '扫描件识别增强（MinerU）', 'AI 提供方'],
    SettingsGroup.appearance: ['主题外观', '深色模式'],
    SettingsGroup.sync: ['局域网同步', '提醒与复习'],
    SettingsGroup.advanced: ['调试日志', '使用说明'],
  };

  for (final entry in groupMarkers.entries) {
    testWidgets('${entry.key.label}组只显示自己的区块（索引表未错位）',
        (tester) async {
      await showSettings(tester, FakeSettingsState(), FailingSync(),
          FakeReminderActions(),
          group: entry.key);
      for (final text in entry.value) {
        expect(find.text(text), findsOneWidget, reason: '缺少「$text」区块');
      }
      // 别的组独有标题不该串进来（索引整体偏移时会串组）
      for (final other in groupMarkers.entries) {
        if (other.key == entry.key) continue;
        final marker = other.value.first;
        expect(find.text(marker), findsNothing,
            reason: '「${entry.key.label}」组里不该出现「$marker」');
      }
    });
  }

  for (final started in [false, true]) {
    testWidgets(
        'auto sync ${started ? 'application' : 'startup'} failure keeps off and allows retry',
        (tester) async {
      final app = FakeSettingsState();
      final sync = FailingSync()..running = started;
      await showSettings(tester, app, sync, FakeReminderActions());
      await tester.tap(find.text('自动同步已关闭'));
      await tester.pumpAndSettle();
      expect(app.settings.autoSync, isFalse);
      expect(find.textContaining('自动同步设置失败'), findsOneWidget);
      sync.fail = false;
      await tester.tap(find.text('自动同步已关闭'));
      await tester.pumpAndSettle();
      expect(app.settings.autoSync, isTrue);
      expect(find.text('自动同步已开启'), findsOneWidget);
      expect(find.textContaining('自动同步设置失败'), findsNothing);
    });
  }

  testWidgets('denied permission never enables reminder; granting allows retry',
      (tester) async {
    final app = FakeSettingsState();
    final actions = FakeReminderActions();
    await showSettings(tester, app, FailingSync(), actions);
    final toggle = find.byKey(const ValueKey('settings-reminder-switch'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.reminderEnabled, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.textContaining('提醒未开启'), findsOneWidget);
    actions.granted = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.reminderEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('reminder schedule failure rolls back and displays failure',
      (tester) async {
    final app = FakeSettingsState();
    final actions = FakeReminderActions()
      ..granted = true
      ..failSchedule = true;
    await showSettings(tester, app, FailingSync(), actions);
    final toggle = find.byKey(const ValueKey('settings-reminder-switch'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.reminderEnabled, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.textContaining('提醒设置失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored reminder is not shown enabled without permission',
      (tester) async {
    final app = FakeSettingsState()..reminder = true;
    await showSettings(tester, app, FailingSync(), FakeReminderActions());
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('settings-reminder-switch')))
            .value,
        isFalse);
    expect(find.textContaining('提醒不可用'), findsOneWidget);
  });
}
