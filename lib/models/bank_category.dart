/// 题库分类节点（schema v15 · 分类树）。
///
/// 分类是**用户自建的树**：`parentId == null` 即根分类，靠 `parentId`
/// 自引用形成任意层级的分类树；题库通过 `QuestionBank.categoryId`
/// 挂到某个分类下（`null` = 未分类）。
///
/// 为什么不是「题库加个标签字符串」：分类要能层层折叠、整支移动、
/// 删父级时子级与题库上移一级而不是连带删除，这些都需要真正的树结构。
class BankCategory {
  final int? id;
  final String name;

  /// 父分类 id；`null` = 根分类
  final int? parentId;

  /// 同级排序（越小越靠前）
  final int sortOrder;

  final String createdAt;

  const BankCategory({
    this.id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'parent_id': parentId,
      'sort_order': sortOrder,
      'created_at': createdAt,
    };
  }

  factory BankCategory.fromMap(Map<String, dynamic> map) {
    return BankCategory(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      parentId: map['parent_id'] as int?,
      sortOrder: map['sort_order'] as int? ?? 0,
      createdAt: map['created_at'] as String? ?? '',
    );
  }

  BankCategory copyWith({
    int? id,
    String? name,
    int? parentId,
    int? sortOrder,
    String? createdAt,
  }) {
    return BankCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
