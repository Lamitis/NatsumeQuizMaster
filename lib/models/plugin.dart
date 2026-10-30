/// 插件（schema v13 · world-overview）。
///
/// 插件是**声明式包**：一个 `plugin.json` 清单 + 可选资产（提示词、内置知识库、
/// 示例题库）。能力映射到 App 内置函数，**不执行任意第三方代码**（安全红线）。
/// [manifest] 存清单原文 JSON；[enabled] 表示用户是否启用。
class PluginInfo {
  final String id;
  final String name;
  final String version;
  final String? author;
  final String? description;
  final String manifest; // 清单 JSON 原文
  final bool enabled;
  final String installedAt;

  PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    this.author,
    this.description,
    this.manifest = '{}',
    this.enabled = true,
    required this.installedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'version': version,
      'author': author,
      'description': description,
      'manifest': manifest,
      'enabled': enabled ? 1 : 0,
      'installed_at': installedAt,
    };
  }

  factory PluginInfo.fromMap(Map<String, dynamic> map) {
    return PluginInfo(
      id: map['id'] as String,
      name: map['name'] as String,
      version: map['version'] as String,
      author: map['author'] as String?,
      description: map['description'] as String?,
      manifest: map['manifest'] as String? ?? '{}',
      enabled: map['enabled'] != 0,
      installedAt: map['installed_at'] as String? ?? '',
    );
  }

  PluginInfo copyWith({
    String? id,
    String? name,
    String? version,
    String? author,
    String? description,
    String? manifest,
    bool? enabled,
    String? installedAt,
  }) {
    return PluginInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      author: author ?? this.author,
      description: description ?? this.description,
      manifest: manifest ?? this.manifest,
      enabled: enabled ?? this.enabled,
      installedAt: installedAt ?? this.installedAt,
    );
  }
}
