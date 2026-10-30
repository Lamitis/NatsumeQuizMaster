/// 知识库文档（schema v13）。
///
/// 用户导入知识库时，一个原始文件（txt/md/docx/pdf）对应一条文档记录，
/// 解析后的全文存 [content]，再切成 [KbChunk] 供检索。
class KbDocument {
  final int? id;
  final int kbId;
  final String name; // 文件名（不含扩展名或含扩展名，导入时由调用方决定）
  final String? source; // 来源说明：'txt'/'md'/'docx'/'pdf'/'paste'
  final String? fileExt; // 原始扩展名（如 'docx'）
  final String content; // 解析后的纯文本全文
  final String createdAt;
  final String? uid;

  KbDocument({
    this.id,
    required this.kbId,
    required this.name,
    this.source,
    this.fileExt,
    this.content = '',
    required this.createdAt,
    this.uid,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'kb_id': kbId,
      'name': name,
      'source': source,
      'file_ext': fileExt,
      'content': content,
      'created_at': createdAt,
      'uid': uid,
    };
  }

  factory KbDocument.fromMap(Map<String, dynamic> map) {
    return KbDocument(
      id: map['id'] as int?,
      kbId: map['kb_id'] as int,
      name: map['name'] as String,
      source: map['source'] as String?,
      fileExt: map['file_ext'] as String?,
      content: map['content'] as String? ?? '',
      createdAt: map['created_at'] as String? ?? '',
      uid: map['uid'] as String?,
    );
  }

  KbDocument copyWith({
    int? id,
    int? kbId,
    String? name,
    String? source,
    String? fileExt,
    String? content,
    String? createdAt,
    String? uid,
  }) {
    return KbDocument(
      id: id ?? this.id,
      kbId: kbId ?? this.kbId,
      name: name ?? this.name,
      source: source ?? this.source,
      fileExt: fileExt ?? this.fileExt,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      uid: uid ?? this.uid,
    );
  }
}
