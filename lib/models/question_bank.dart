class QuestionBank {
  final int? id;
  final String name;
  final String? fileSource;
  final int questionCount;
  final String createdAt;

  /// 所属分类（schema v15 分类树）；`null` = 未分类
  final int? categoryId;

  QuestionBank({
    this.id,
    required this.name,
    this.fileSource,
    this.questionCount = 0,
    required this.createdAt,
    this.categoryId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'file_source': fileSource,
      'question_count': questionCount,
      'created_at': createdAt,
      'category_id': categoryId,
    };
  }

  factory QuestionBank.fromMap(Map<String, dynamic> map) {
    return QuestionBank(
      id: map['id'] as int?,
      name: map['name'] as String,
      fileSource: map['file_source'] as String?,
      questionCount: map['question_count'] as int? ?? 0,
      createdAt: map['created_at'] as String,
      categoryId: map['category_id'] as int?,
    );
  }

  QuestionBank copyWith({
    int? id,
    String? name,
    String? fileSource,
    int? questionCount,
    String? createdAt,
    int? categoryId,
    /// 显式把分类清空（回到「未分类」）——`categoryId: null` 在 copyWith 里
    /// 代表「不改」，所以要清空必须走这个开关
    bool clearCategory = false,
  }) {
    return QuestionBank(
      id: id ?? this.id,
      name: name ?? this.name,
      fileSource: fileSource ?? this.fileSource,
      questionCount: questionCount ?? this.questionCount,
      createdAt: createdAt ?? this.createdAt,
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
    );
  }
}
