import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/screens/note_editor_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 笔记富文本工具栏（v1.40）。
///
/// 需求：选中文字点按钮 → 自动包裹对应 Markdown / HTML 符号；未选中 →
/// 插入空标签并把光标放中间。这里逐项验证写进去的**就是渲染引擎认识的
/// 标记**（`**` / `<mark>` / `<span style="color: #HEX">` / `$` / 列表 / 围栏）。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_note_toolbar_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<TextEditingController> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState appState;
    await tester.runAsync(() async {
      appState = AppState();
      await appState.init();
    });
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(
        theme: ThemeService().themeData,
        home: const NoteEditorScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    final body = find.byType(TextField).at(1);
    final controller = tester.widget<TextField>(body).controller!;
    await tester.enterText(body, '公式');
    // 全选正文（等价于用户拖选）
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.pump();
    return controller;
  }

  testWidgets('加粗 / 高亮：选中文字自动包裹', (tester) async {
    final controller = await pumpEditor(tester);

    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(controller.text, '**公式**');

    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.pump();
    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();
    expect(controller.text, '<mark>**公式**</mark>');
  });

  testWidgets('文字颜色：色盘选中后插入 span style', (tester) async {
    final controller = await pumpEditor(tester);

    await tester.tap(find.byTooltip('文字颜色'));
    await tester.pumpAndSettle();
    expect(find.text('选择文字颜色'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('noteColor蓝')));
    await tester.pumpAndSettle();

    expect(controller.text,
        '<span style="color: #2F6FEB">公式</span>');
  });

  testWidgets('行内公式 / 代码块：插入配对标记', (tester) async {
    final controller = await pumpEditor(tester);

    await tester.tap(find.byTooltip('行内公式'));
    await tester.pump();
    expect(controller.text, r'$公式$');

    // 代码块：选中内容进围栏
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.pump();
    await tester.tap(find.byTooltip('代码块'));
    await tester.pump();
    expect(controller.text, '```\n\$公式\$\n```');
  });

  testWidgets('有序 / 无序列表：逐行加前缀', (tester) async {
    final controller = await pumpEditor(tester);
    await tester.enterText(find.byType(TextField).at(1), '第一行\n第二行');
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.pump();

    await tester.tap(find.byTooltip('无序列表'));
    await tester.pump();
    expect(controller.text, '- 第一行\n- 第二行');

    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.pump();
    await tester.tap(find.byTooltip('有序列表'));
    await tester.pump();
    // 已有 '-' 前缀会被替换成递增编号，而不是叠成 "- 1. "
    expect(controller.text, '1. 第一行\n2. 第二行');
  });

  testWidgets('未选中文字：插入空标签且光标落在中间', (tester) async {
    final controller = await pumpEditor(tester);

    // 光标放到文末（不选中任何内容）
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);
    await tester.pump();

    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();

    expect(controller.text, '公式<mark></mark>');
    expect(controller.selection.isCollapsed, isTrue);
    expect(controller.selection.baseOffset, '公式<mark>'.length,
        reason: '光标应落在开闭标签之间，直接开打就是标签里的字');
  });
}
