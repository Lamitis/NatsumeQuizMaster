/// 笔记（v1.31 · 笔记插件）。
///
/// 设计取形于 Logseq 的「双链笔记」：一页笔记按题库归类，正文里写
/// `[[另一页]]` 就形成一条链接，反向可查「谁引用了我」，正向聚合出图谱。
/// 这里只复用它的**格式与交互习惯**，不引入上游代码；Logseq 与本工程同为
/// AGPL-3.0，署名见 `THIRD_PARTY_NOTICES.md`。
///
/// 注意：笔记属于**本机数据**（插件数据），`sync_repository.dart` 的导出清单
/// 只有题库/题目/会话/记录/错题/批注，不含 `notes`/`note_links`
/// ——界面上必须明示「无法同步」，不能让用户以为换机还在。
library;

/// 双链 / 标签解析与展示的纯函数集合（无 IO，便于单测）。
class NoteLinks {
  const NoteLinks._();

  /// `[[目标]]` 或 `[[目标|显示名]]`
  static final RegExp bracket = RegExp(r'\[\[([^\[\]\n]+)\]\]');

  /// `#标签`（行首或空白之后；避免把 URL 里的 # 当成标签）
  static final RegExp tag = RegExp(r'(?:^|\s)#([^\s#\[\]，。；、,.;:：!?！？]{1,32})');

  /// 抽取笔记正文里引用的所有页面（去重、保持出现顺序）。
  ///
  /// `[[目标|显示名]]` 只取「目标」——图谱按页面标题连边，显示名只是排版。
  static List<String> extractTargets(String content) {
    final out = <String>[];
    void add(String raw) {
      var t = raw.trim();
      if (t.isEmpty) return;
      final pipe = t.indexOf('|');
      if (pipe >= 0) t = t.substring(0, pipe).trim();
      if (t.isEmpty || out.contains(t)) return;
      out.add(t);
    }

    for (final m in bracket.allMatches(content)) {
      add(m.group(1) ?? '');
    }
    for (final m in tag.allMatches(content)) {
      add(m.group(1) ?? '');
    }
    return out;
  }

  /// 把正文压成一行纯文本摘要（用于列表预览）。
  static String plainText(String content, {int maxChars = 80}) {
    final s = content
        .replaceAllMapped(
            bracket, (m) => (m.group(1) ?? '').split('|').first)
        .replaceAllMapped(
            RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
        .replaceAll(RegExp(r'[*_`>#]+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length <= maxChars) return s;
    return '${s.substring(0, maxChars)}…';
  }
}

/// 一条笔记。
class Note {
  final int? id;

  /// 归属题库（空 = 未归类；题库被删后仍保留笔记，只显示「已删除题库」）
  final int? bankId;

  /// 从刷题页「写笔记」进来时绑定到具体题目
  final int? questionId;

  final String title;
  final String content;
  final String createdAt;
  final String updatedAt;

  const Note({
    this.id,
    this.bankId,
    this.questionId,
    required this.title,
    this.content = '',
    required this.createdAt,
    required this.updatedAt,
  });

  /// 正文里的双链/标签目标
  List<String> get targets => NoteLinks.extractTargets(content);

  String get excerpt => NoteLinks.plainText(content);

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'bank_id': bankId,
        'question_id': questionId,
        'title': title,
        'content': content,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Note.fromMap(Map<String, dynamic> map) => Note(
        id: map['id'] as int?,
        bankId: map['bank_id'] as int?,
        questionId: map['question_id'] as int?,
        title: (map['title'] as String?) ?? '',
        content: (map['content'] as String?) ?? '',
        createdAt: (map['created_at'] as String?) ?? '',
        updatedAt: (map['updated_at'] as String?) ?? '',
      );

  Note copyWith({
    int? id,
    int? bankId,
    int? questionId,
    String? title,
    String? content,
    String? createdAt,
    String? updatedAt,
  }) =>
      Note(
        id: id ?? this.id,
        bankId: bankId ?? this.bankId,
        questionId: questionId ?? this.questionId,
        title: title ?? this.title,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 按题库分组的笔记（「按照题库名称分类」）
class NoteGroup {
  final int? bankId;
  final String bankName;
  final List<Note> notes;

  const NoteGroup({
    required this.bankId,
    required this.bankName,
    required this.notes,
  });
}

/// 图谱节点：一个页面标题（可能是尚未落成笔记的「悬空页」）
class NoteNode {
  final String id;
  final int? noteId;
  final int degree;
  final bool missing;

  const NoteNode({
    required this.id,
    required this.noteId,
    required this.degree,
    required this.missing,
  });
}

/// 图谱边：from → to（按标题）
class NoteEdge {
  final String from;
  final String to;

  const NoteEdge({required this.from, required this.to});

  @override
  bool operator ==(Object other) =>
      other is NoteEdge && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// 图谱数据（渲染交给 `widgets/note_graph_view.dart`）
class NoteGraph {
  final List<NoteNode> nodes;
  final List<NoteEdge> edges;

  const NoteGraph({required this.nodes, required this.edges});

  bool get isEmpty => nodes.isEmpty;

  static const NoteGraph empty = NoteGraph(nodes: [], edges: []);
}
