/// 日程待办（schema v16 · 日程待办插件）。
///
/// 为什么单独建表而不是塞进 settings：待办要按到期日排序、按完成状态筛选、
/// 逐条增删改。存成一段 JSON 的 settings 值后，每次勾选都要读全量再写回，
/// 勾一半被系统杀掉就整批丢了。
///
/// 与笔记同一条边界：**不加外键**（待办与题库无关）。
/// v1.35 起随局域网同步（按 `uid` 合并，可在「设置 → 同步与提醒」里按插件关掉），
/// 界面文案要跟着开关走。
class ScheduleItem {
  final int? id;

  /// 跨设备唯一 id（v1.35 同步；老数据在 v17 迁移时补）
  final String? uid;

  /// 产生这条待办的设备（null / 空 = 本机）
  final String? originDevice;

  final String title;

  /// 备注（可选，展示在标题下一行）
  final String detail;

  /// 到期时间；null = 无期限的纯待办
  final DateTime? dueAt;

  final bool done;
  final String createdAt;
  final String updatedAt;

  ScheduleItem({
    this.id,
    this.uid,
    this.originDevice,
    required this.title,
    this.detail = '',
    this.dueAt,
    this.done = false,
    String? createdAt,
    String? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toIso8601String(),
        updatedAt = updatedAt ?? DateTime.now().toIso8601String();

  /// 是否已逾期（未完成且到期时间已过）——列表里要标红
  bool isOverdue({DateTime? now}) =>
      !done && dueAt != null && dueAt!.isBefore(now ?? DateTime.now());

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        if (uid != null) 'uid': uid,
        if (originDevice != null) 'origin_device': originDevice,
        'title': title,
        'detail': detail,
        'due_at': dueAt?.toIso8601String(),
        'done': done ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory ScheduleItem.fromMap(Map<String, dynamic> map) => ScheduleItem(
        id: map['id'] as int?,
        uid: map['uid'] as String?,
        originDevice: map['origin_device'] as String?,
        title: (map['title'] as String?) ?? '',
        detail: (map['detail'] as String?) ?? '',
        dueAt: DateTime.tryParse((map['due_at'] as String?) ?? ''),
        done: (map['done'] as int? ?? 0) != 0,
        createdAt: (map['created_at'] as String?) ?? '',
        updatedAt: (map['updated_at'] as String?) ?? '',
      );

  ScheduleItem copyWith({
    int? id,
    String? uid,
    String? originDevice,
    String? title,
    String? detail,
    DateTime? dueAt,
    bool clearDue = false,
    bool? done,
    String? createdAt,
    String? updatedAt,
  }) =>
      ScheduleItem(
        id: id ?? this.id,
        uid: uid ?? this.uid,
        originDevice: originDevice ?? this.originDevice,
        title: title ?? this.title,
        detail: detail ?? this.detail,
        // dueAt 为 null 有两种语义（清空 / 不改），用 clearDue 显式区分
        dueAt: clearDue ? null : (dueAt ?? this.dueAt),
        done: done ?? this.done,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
