import 'dart:convert';

/// 插件内容同步范围（v1.35）。
///
/// 「要不要把插件数据带进局域网快照」是**每台设备各自的选择**，所以存在本机
/// settings 表的一行 JSON（[settingsKey]）里，不随快照传播——否则手机端关掉
/// 同步，会把桌面端也一起关掉。
///
/// 默认三项全开：用户要的是「笔记 / 助教 / 待办能同步上去」，关是例外而非常态。
/// 但助教的 API Key、悬浮位置、好感度**永远不参与同步**（见 SyncRepository）。
class PluginSyncScope {
  const PluginSyncScope({
    this.notes = true,
    this.companion = true,
    this.schedule = true,
  });

  /// 本机是否同步笔记（`natsume.notes`）
  final bool notes;

  /// 本机是否同步助教人设与记忆（`natsume.companion`）
  final bool companion;

  /// 本机是否同步日程待办（`natsume.schedule`）
  final bool schedule;

  /// settings 表键名（改键 = 老用户选择丢失，勿改）
  static const String settingsKey = 'plugin_sync_scope_v1';

  /// 内置插件 id（与 BuiltinPlugins 保持一致；这里写死是为了不让 model 依赖 service）
  static const String notesPluginId = 'natsume.notes';
  static const String companionPluginId = 'natsume.companion';
  static const String schedulePluginId = 'natsume.schedule';

  static const PluginSyncScope all = PluginSyncScope();

  bool get anyEnabled => notes || companion || schedule;

  bool enabledFor(String pluginId) => switch (pluginId) {
        notesPluginId => notes,
        companionPluginId => companion,
        schedulePluginId => schedule,
        _ => false,
      };

  PluginSyncScope copyWith({bool? notes, bool? companion, bool? schedule}) =>
      PluginSyncScope(
        notes: notes ?? this.notes,
        companion: companion ?? this.companion,
        schedule: schedule ?? this.schedule,
      );

  /// 按插件 id 改一项（世界总览 / 设置页共用同一条入口）
  PluginSyncScope withPlugin(String pluginId, bool enabled) =>
      switch (pluginId) {
        notesPluginId => copyWith(notes: enabled),
        companionPluginId => copyWith(companion: enabled),
        schedulePluginId => copyWith(schedule: enabled),
        _ => this,
      };

  Map<String, dynamic> toJson() => {
        'notes': notes,
        'companion': companion,
        'schedule': schedule,
      };

  String encode() => jsonEncode(toJson());

  /// 容错解析：坏 JSON / 缺字段一律按默认（全开），不因为一行设置坏掉同步
  factory PluginSyncScope.decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return all;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return all;
      bool flag(String key) {
        final v = decoded[key];
        if (v is bool) return v;
        if (v == null) return true;
        final s = v.toString().toLowerCase();
        return s == '1' || s == 'true';
      }

      return PluginSyncScope(
        notes: flag('notes'),
        companion: flag('companion'),
        schedule: flag('schedule'),
      );
    } catch (_) {
      return all;
    }
  }

  @override
  String toString() =>
      'PluginSyncScope(notes: $notes, companion: $companion, schedule: $schedule)';
}
