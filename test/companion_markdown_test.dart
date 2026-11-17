import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/services/companion/companion_service.dart';
import 'package:natsume_quiz_master/utils/companion_text.dart';

/// v1.43 小鲸助教的 Markdown 清洗契约：
/// 外层 ```markdown 围栏必须剥掉，正文里的代码块必须保留。
void main() {
  test('剥掉外层 ```markdown 围栏，保留加粗/标题等正文标记', () {
    const raw = '''```markdown
### 休克的治疗
**第一步**：液体复苏。
1. 快速补液
2. 血管活性药
```''';
    final cleaned = cleanCompanionMarkdown(raw);
    expect(cleaned, startsWith('### 休克的治疗'));
    expect(cleaned, contains('**第一步**'));
    expect(cleaned, isNot(contains('```markdown')));
    expect(cleaned, isNot(contains('```')));
  });

  test('无名围栏包裹整段回复也会被剥掉', () {
    const raw = '''```
直接回答，不带围栏。
```''';
    expect(cleanCompanionMarkdown(raw), '直接回答，不带围栏。');
  });

  test('正文里真正的代码块保留（只剥最外层）', () {
    const raw = '''```markdown
示例代码：
```dart
print('hi');
```
以上是示例。
```''';
    final cleaned = cleanCompanionMarkdown(raw);
    expect(cleaned, contains('```dart'));
    expect(cleaned, contains("print('hi');"));
    expect(cleaned, isNot(startsWith('```markdown')));
    expect(cleaned, endsWith('以上是示例。'));
  });

  test('只有结尾围栏（模型漏写开头）也不把正文当代码块', () {
    expect(cleanCompanionMarkdown('正常回复。\n```'), '正常回复。');
  });

  test('零宽字符被清理', () {
    expect(cleanCompanionMarkdown('正\u200B常\u200D回复'), '正常回复');
  });

  test('打字机预览去掉 Markdown 标记，避免中途露源码', () {
    final preview =
        companionTypingPreview('### 标题\n**重点**内容，`code`\n|---|\n正文');
    expect(preview, isNot(contains('###')));
    expect(preview, isNot(contains('**')));
    expect(preview, isNot(contains('`')));
    expect(preview, isNot(contains('|---|')));
    expect(preview, contains('重点'));
    expect(preview, contains('正文'));
  });

  test('System Prompt 明确禁止用 ```markdown 包裹整段回复', () {
    final prompt = CompanionService.instance.systemPrompt();
    expect(prompt, contains('绝对不要'));
    expect(prompt, contains('markdown'));
    expect(prompt, contains('代码块包裹整段回复'));
  });
}
