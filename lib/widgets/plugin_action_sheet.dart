import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/export_storage.dart';
import '../services/plugins/plugin_ui_extension.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import 'ai_response_widget.dart';
import 'kit/natsume_kit.dart';

/// 所有插件 AI 结果都必须带的免责声明（安全护栏 4）。
const String pluginActionDisclaimer = '本结果由第三方插件生成，不代表官方观点';

/// 图标名 → 宿主图标。白名单之外的图标一律用扩展图标，插件无法借图标名
/// 引用任意 Material 图标（也避免清单里写一个不存在的名字导致崩溃）。
const Map<String, IconData> _pluginIcons = {
  'psychology': Icons.psychology_outlined,
  'psychology_alt': Icons.psychology_alt_outlined,
  'lightbulb': Icons.lightbulb_outline,
  'school': Icons.school_outlined,
  'quiz': Icons.quiz_outlined,
  'auto_awesome': Icons.auto_awesome_outlined,
  'menu_book': Icons.menu_book_outlined,
  'tips_and_updates': Icons.tips_and_updates_outlined,
  'translate': Icons.translate,
  'summarize': Icons.summarize_outlined,
  'checklist': Icons.checklist_rtl,
  'insights': Icons.insights,
  'extension': Icons.extension_outlined,
};

IconData pluginIconFor(String name) =>
    _pluginIcons[name] ?? Icons.extension_outlined;

/// 动态 UI 插槽里的图标按钮：文字只进 tooltip，避免挤占解析区。
class PluginActionIconButton extends StatelessWidget {
  const PluginActionIconButton({
    super.key,
    required this.extension,
    this.onPressed,
  });

  final PluginUiExtension extension;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: ValueKey('plugin-action-${extension.key}'),
      tooltip: extension.label,
      visualDensity: VisualDensity.compact,
      icon: Icon(pluginIconFor(extension.icon), size: 20),
      onPressed: onPressed,
    );
  }
}

/// 弹出插件动作结果：统一限宽底部弹层 + 流式渲染 + 免责声明。
Future<void> showPluginActionResultSheet(
  BuildContext context, {
  required String title,
  required Stream<String> stream,
  String? pluginName,
  String? subtitle,
  String renderer = PluginRenderers.bottomSheet,
  String? saveFileName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppThemeColors.of(context).background,
    constraints: const BoxConstraints(maxWidth: kSheetMaxWidth),
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(NatsumeRadius.card)),
    ),
    builder: (_) => PluginActionResultSheet(
      title: title,
      pluginName: pluginName,
      subtitle: subtitle,
      stream: stream,
      renderer: renderer,
      saveFileName: saveFileName,
    ),
  );
}

/// 插件动作结果弹层。
///
/// 内容是**流式**的：关掉立即断流，没人看的生成不继续烧 token。
/// `renderer == bottom_sheet_foldable` 且正文含 [PluginRenderers.answerStartMarker]
/// 时，标记之前的讲解先展示，答案默认折叠，点开才显示。
class PluginActionResultSheet extends StatefulWidget {
  const PluginActionResultSheet({
    super.key,
    required this.title,
    required this.stream,
    this.pluginName,
    this.subtitle,
    this.renderer = PluginRenderers.bottomSheet,
    this.saveFileName,
  });

  final String title;
  final String? pluginName;
  final String? subtitle;
  final Stream<String> stream;
  final String renderer;
  final String? saveFileName;

  @override
  State<PluginActionResultSheet> createState() =>
      _PluginActionResultSheetState();
}

class _PluginActionResultSheetState extends State<PluginActionResultSheet> {
  StreamSubscription<String>? _sub;
  String _text = '';
  String? _error;
  bool _saving = false;
  bool _answerExpanded = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(
      (acc) {
        if (!mounted) return;
        setState(() => _text = acc);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = '$e');
      },
      onDone: () {
        if (!mounted) return;
        // 空产出也当失败说清楚，别留一个永远转圈的弹层
        if (_text.trim().isEmpty && _error == null) {
          setState(() => _error = '模型没有返回内容，请稍后重试');
        }
      },
      cancelOnError: true,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  bool get _ready => _text.trim().isNotEmpty;

  /// 折叠只看正文标记：`renderer` 声明的是预期交互，真正决定能否折叠的是
  /// AI 是否按约定输出了 `<!--ANSWER_START-->`。这样 `bottom_sheet` 里误带
  /// 标记也不会把答案直接摊开。
  bool get _foldable => _text.contains(PluginRenderers.answerStartMarker);

  String get _reasoningText {
    final index = _text.indexOf(PluginRenderers.answerStartMarker);
    return index < 0 ? _text : _text.substring(0, index).trim();
  }

  String get _answerText {
    final index = _text.indexOf(PluginRenderers.answerStartMarker);
    if (index < 0) return '';
    return _text
        .substring(index + PluginRenderers.answerStartMarker.length)
        .trim();
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _text));
    messenger.showSnackBar(const SnackBar(
      duration: Duration(seconds: 2),
      content: Text('已复制到剪贴板'),
    ));
  }

  /// 存成 .md：复用错题导出那套「另存为」，取消不报成功。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final result = await ExportStorage.saveAsBytes(
      Uint8List.fromList(utf8.encode(_text)),
      fileName: widget.saveFileName ?? _defaultFileName(),
      dialogTitle: '保存${widget.title}',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.saved) {
      messenger.showSnackBar(const SnackBar(content: Text('已取消保存')));
      return;
    }
    final path = result.path!;
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('已保存：${ExportStorage.folderOf(path)}',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(
        label: '复制路径',
        onPressed: () => Clipboard.setData(ClipboardData(text: path)),
      ),
    ));
  }

  String _defaultFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}';
    final safeTitle = widget.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '${safeTitle}_$stamp.md';
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: NatsumeSpace.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: ac.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NatsumeSpace.lg, NatsumeSpace.sm, NatsumeSpace.sm, 0),
              child: Row(
                children: [
                  Icon(Icons.extension_outlined, size: 20, color: ac.accent),
                  const SizedBox(width: NatsumeSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NatsumeType.h3Style
                                .copyWith(color: ac.textPrimary)),
                        if (widget.pluginName != null)
                          Text(widget.pluginName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NatsumeType.microStyle
                                  .copyWith(color: ac.textTertiary)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    NatsumeSpace.lg, NatsumeSpace.xxs, NatsumeSpace.lg, 0),
                child: Text(widget.subtitle!,
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textSecondary)),
              ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
                minHeight: 72,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(NatsumeSpace.lg),
                child: _body(ac),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NatsumeSpace.lg, 0, NatsumeSpace.lg, NatsumeSpace.xs),
              child: Text(
                pluginActionDisclaimer,
                textAlign: TextAlign.center,
                style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  NatsumeSpace.lg, 0, NatsumeSpace.lg, NatsumeSpace.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  NatsumeButton(
                    label: '复制',
                    kind: NatsumeButtonKind.secondary,
                    dense: true,
                    icon: Icons.copy_all_outlined,
                    onPressed: _ready ? _copy : null,
                  ),
                  const SizedBox(width: NatsumeSpace.xs),
                  NatsumeButton(
                    label: _saving ? '保存中…' : '保存为 .md',
                    kind: NatsumeButtonKind.secondary,
                    dense: true,
                    icon: Icons.save_alt,
                    onPressed: _ready && !_saving ? _save : null,
                  ),
                  const SizedBox(width: NatsumeSpace.xs),
                  NatsumeButton(
                    label: '关闭',
                    dense: true,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AppThemeColors ac) {
    final error = _error;
    if (error != null) {
      return Text(
        '生成失败：$error',
        style: TextStyle(fontSize: NatsumeType.body, color: ac.danger),
      );
    }
    if (!_ready) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: NatsumeSpace.sm),
          Expanded(
            child: Text(
              '正在生成…',
              style: TextStyle(
                  fontSize: NatsumeType.body, color: ac.textSecondary),
            ),
          ),
        ],
      );
    }
    if (!_foldable) {
      // 非折叠渲染器里也要藏掉标记本身，别把 HTML 注释摊给用户看
      final text =
          _text.replaceAll(PluginRenderers.answerStartMarker, '').trim();
      return SelectionArea(
        child: AiResponseWidget(text: text, fontSize: NatsumeType.body),
      );
    }
    // 折叠交互：先展示讲解，答案要点开才出现，避免一上来就剧透
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_reasoningText.isNotEmpty)
          SelectionArea(
            child: AiResponseWidget(
                text: _reasoningText, fontSize: NatsumeType.body),
          ),
        const SizedBox(height: NatsumeSpace.sm),
        OutlinedButton.icon(
          icon: Icon(
            _answerExpanded
                ? Icons.keyboard_arrow_up
                : Icons.keyboard_arrow_down,
            size: 18,
          ),
          label: Text(_answerExpanded ? '收起答案' : '展开查看答案'),
          onPressed: () => setState(() => _answerExpanded = !_answerExpanded),
        ),
        if (_answerExpanded) ...[
          const SizedBox(height: NatsumeSpace.sm),
          SelectionArea(
            child:
                AiResponseWidget(text: _answerText, fontSize: NatsumeType.body),
          ),
        ],
      ],
    );
  }
}
