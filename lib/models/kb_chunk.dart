/// 知识库文本块（schema v13）。
///
/// 检索的基本单位。一块 = 一段语义完整、适合喂给模型的文本，
/// 由 [KbChunker] 从文档全文切出。[position] 保持原文顺序（同文档内 0 起）。
class KbChunk {
  final int? id;
  final int docId;
  final int kbId;
  final int position;
  final String text;
  final String createdAt;

  KbChunk({
    this.id,
    required this.docId,
    required this.kbId,
    required this.position,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'doc_id': docId,
      'kb_id': kbId,
      'position': position,
      'text': text,
      'created_at': createdAt,
    };
  }

  factory KbChunk.fromMap(Map<String, dynamic> map) {
    return KbChunk(
      id: map['id'] as int?,
      docId: map['doc_id'] as int,
      kbId: map['kb_id'] as int,
      position: map['position'] as int? ?? 0,
      text: map['text'] as String? ?? '',
      createdAt: map['created_at'] as String? ?? '',
    );
  }

  KbChunk copyWith({
    int? id,
    int? docId,
    int? kbId,
    int? position,
    String? text,
    String? createdAt,
  }) {
    return KbChunk(
      id: id ?? this.id,
      docId: docId ?? this.docId,
      kbId: kbId ?? this.kbId,
      position: position ?? this.position,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
