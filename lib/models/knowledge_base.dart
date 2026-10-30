/// 知识库（schema v13）。
///
/// 知识库是「本地优先 AI」的约束来源：用户导入课件/笔记/教材等文档，
/// 切成文本块，检索后注入 AI 提示词，让解释与生成答案只依据库内资料、
/// 不凭空发挥（防幻觉）。知识库与题库相互独立，可分别导入/导出。
class KnowledgeBase {
  final int? id;
  final String name;
  final String? description;
  final String createdAt;
  final String? uid; // 局域网/跨端同步：跨设备唯一标识
  final String? updatedAt;

  KnowledgeBase({
    this.id,
    required this.name,
    this.description,
    required this.createdAt,
    this.uid,
    this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'created_at': createdAt,
      'uid': uid,
      'updated_at': updatedAt,
    };
  }

  factory KnowledgeBase.fromMap(Map<String, dynamic> map) {
    return KnowledgeBase(
      id: map['id'] as int?,
      name: map['name'] as String,
      description: map['description'] as String?,
      createdAt: map['created_at'] as String? ?? '',
      uid: map['uid'] as String?,
      updatedAt: map['updated_at'] as String?,
    );
  }

  KnowledgeBase copyWith({
    int? id,
    String? name,
    String? description,
    String? createdAt,
    String? uid,
    String? updatedAt,
  }) {
    return KnowledgeBase(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      uid: uid ?? this.uid,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
