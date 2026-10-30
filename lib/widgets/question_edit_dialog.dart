import 'package:flutter/material.dart';
import '../models/question.dart';
import '../models/question_edit.dart';
import '../models/question_image.dart';
import '../utils/design_tokens.dart';

class QuestionEditDialog extends StatefulWidget {
  final Question question;

  /// [onSave] 带回编辑后的完整字段：删掉的配图会连同题内 `{{img:N}}` 占位符
  /// 一起移除（由调用方/AppState 统一清理）
  final void Function(QuestionEditResult result) onSave;

  /// 弹窗标题：题库管理里「新建题目」复用本弹窗，标题要跟着语境变
  final String title;

  const QuestionEditDialog({
    super.key,
    required this.question,
    required this.onSave,
    this.title = '编辑题目',
  });

  @override
  State<QuestionEditDialog> createState() => _QuestionEditDialogState();
}

class _QuestionEditDialogState extends State<QuestionEditDialog> {
  late TextEditingController _titleCtrl;
  late TextEditingController _answerCtrl;
  late TextEditingController _analysisCtrl;
  late TextEditingController _kpCtrl;

  /// 选项逐条编辑（选择题才有意义）；保存时丢弃空行后按 A/B/C 顺序重排
  late List<TextEditingController> _optionCtrls;
  late String? _type;
  late List<QuestionImage> _images;

  /// 有选项的题型（其余题型保留原选项不动，不展示选项编辑区）
  static const Set<String> _optionTypes = {'single_choice', 'multi_choice'};

  static const _types = {
    'single_choice': '单选',
    'multi_choice': '多选',
    'true_false': '判断',
    'fill_blank': '填空',
    'jian_da': '简答',
    'ming_jie': '名解',
    // v1.0.2 修复：问答型题目编辑不再触发 DropdownButton 断言崩溃
    'jie_da': '问答',
  };

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.question.title);
    _answerCtrl = TextEditingController(text: widget.question.correctAnswer);
    _analysisCtrl = TextEditingController(text: widget.question.analysis ?? '');
    _kpCtrl = TextEditingController(text: widget.question.knowledgePoint);
    _optionCtrls = [
      for (final o in widget.question.options) TextEditingController(text: o),
    ];
    // v1.0.2 修复：未知题型兜底为单选，避免 value 不在 items 中触发断言
    _type = _types.containsKey(widget.question.questionType)
        ? widget.question.questionType
        : 'single_choice';
    _images = List.of(widget.question.images);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _answerCtrl.dispose();
    _analysisCtrl.dispose();
    _kpCtrl.dispose();
    for (final c in _optionCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// 选项序号 → 选项标签（A/B/C…）
  String _optionLabel(int i) => String.fromCharCode(65 + i);

  /// 保存用的选项：去掉首尾空白与空行（用户删掉文字等于删掉该选项）
  List<String> _currentOptions() => [
        for (final c in _optionCtrls)
          if (c.text.trim().isNotEmpty) c.text.trim(),
      ];

  void _addOption() {
    setState(() => _optionCtrls.add(TextEditingController()));
  }

  void _removeOption(int index) {
    setState(() {
      _optionCtrls.removeAt(index).dispose();
    });
  }

  /// 保存前校验：只挡「必然无意义」的编辑，不误伤导入题库里各种答案写法
  String? _validate() {
    if (_titleCtrl.text.trim().isEmpty) return '题干不能为空';
    if (!_optionTypes.contains(_type)) return null;
    final opts = _currentOptions();
    if (opts.length < 2) return '选择题至少要 2 个选项（现在是 ${opts.length} 个）';
    final ans = _answerCtrl.text.trim();
    if (ans.isEmpty) return '请填写正确答案（多选可用逗号分隔，如 A,C）';
    // 空行保存时会被丢弃、选项按 A/B/C 重排，所以这里用重排后的标签比对
    final labels = [for (var i = 0; i < opts.length; i++) _optionLabel(i)];
    // 只校验「单个字母」形式的答案是否越界；整段文字答案（部分导入题库如此）跳过
    for (final token in ans.split(RegExp(r'[,，、;；\s]+'))) {
      if (token.length != 1) continue;
      final c = token.toUpperCase();
      if (!RegExp(r'^[A-Z]$').hasMatch(c)) continue;
      if (!labels.contains(c)) return '答案「$c」超出选项范围（A~${labels.last}）';
    }
    return null;
  }

  void _save() {
    final err = _validate();
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final analysis = _analysisCtrl.text.trim();
    widget.onSave(QuestionEditResult(
      title: _titleCtrl.text.trim(),
      answer: _answerCtrl.text.trim(),
      type: _type,
      images: _images,
      // 非选择题保留原选项，避免把判断题/简答题的选项清空
      options: _optionTypes.contains(_type)
          ? _currentOptions()
          : widget.question.options,
      // 空串 = 用户清空了解析（null 在落库层表示「不更新」）
      analysis: analysis,
      knowledgePoint: _kpCtrl.text.trim(),
    ));
    Navigator.pop(context);
  }

  /// 删图：图片是题目的一部分，占位符随之从题干移除（挪图则直接改题干文本）
  void _removeImage(QuestionImage img) {
    setState(() {
      _images = _images.where((i) => i.position != img.position).toList();
      _titleCtrl.text = _titleCtrl.text.replaceAll('{{img:${img.position}}}', '');
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String?>(
              value: _type,
              decoration: const InputDecoration(labelText: '题型', border: OutlineInputBorder()),
              items: _types.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() => _type = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '题干', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _answerCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: _optionTypes.contains(_type)
                    ? '答案（多选用逗号分隔，如 A,C）'
                    : '答案',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_optionTypes.contains(_type)) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('选项',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addOption,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加选项'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (var i = 0; i < _optionCtrls.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text('${_optionLabel(i)}.',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _optionCtrls[i],
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '选项 ${_optionLabel(i)}',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      // 至少留 2 个选项，删到 2 个以下时按钮置灰（保存前还会再校验）
                      IconButton(
                        tooltip: '删除该选项',
                        onPressed:
                            _optionCtrls.length > 2 ? () => _removeOption(i) : null,
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _kpCtrl,
              decoration: const InputDecoration(
                labelText: '知识点（留空＝未分类）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _analysisCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '解析（可留空）',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            if (_images.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('题目配图 · 题干里 {{img:N}} 标位置，可改文本挪图',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final img in _images)
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: NatsumeRadius.smallBorder,
                                child: Image.memory(img.content, fit: BoxFit.cover),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              // 删图角标：视觉维持原小角标不动，热区扩到 40×40
                              //（触达目标下限）——原来可点区域只有十几像素，很难点中
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => _removeImage(img),
                                  child: Align(
                                    alignment: Alignment.topRight,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: const BoxDecoration(
                                          color: Colors.black54,
                                          shape: BoxShape.circle),
                                      child: const Icon(Icons.close,
                                          size: 12, color: Colors.white),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
