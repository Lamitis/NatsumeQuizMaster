/// 世界（schema v13 · world-overview）。
///
/// 「世界」= 知识库 + 题库 + 插件 + AI 预设 的打包单元，可整体导出/导入/分享，
/// 让一套备考内容（含约束 AI 的知识库与出题插件）作为单一 `.natsume-world`
/// 文件在设备间流转。这里是安装后的**登记行**；打包/解包在
/// `lib/services/plugins/world_service.dart`。
class WorldInfo {
  final String id;
  final String name;
  final String version;
  final String manifest; // 世界清单 JSON 原文（含成员引用）
  final String installedAt;

  WorldInfo({
    required this.id,
    required this.name,
    required this.version,
    this.manifest = '{}',
    required this.installedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'version': version,
      'manifest': manifest,
      'installed_at': installedAt,
    };
  }

  factory WorldInfo.fromMap(Map<String, dynamic> map) {
    return WorldInfo(
      id: map['id'] as String,
      name: map['name'] as String,
      version: map['version'] as String,
      manifest: map['manifest'] as String? ?? '{}',
      installedAt: map['installed_at'] as String? ?? '',
    );
  }

  WorldInfo copyWith({
    String? id,
    String? name,
    String? version,
    String? manifest,
    String? installedAt,
  }) {
    return WorldInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      manifest: manifest ?? this.manifest,
      installedAt: installedAt ?? this.installedAt,
    );
  }
}
