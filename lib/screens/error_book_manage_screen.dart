import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/question.dart';
import '../services/app_state.dart';
import '../services/fsrs_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/format_utils.dart';
import '../utils/question_image_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

/// 错题本「删减」页：把**不想再练 / 不需要练**的错题从错题本移除。
///
/// 范围与错题本主列表同口径（当前筛选 + 已选题库），不另起一套查询：
/// 用户在错题本看到多少题，这里就能筛掉多少题。
///
/// 移除只清 FSRS 复习卡与本机收藏，**题库里的题目和历史作答记录都保留**
/// （见 [AppState.removeQuestionsFromErrorBook]）——这是「不想练了」，
/// 不是「把题从题库删掉」。以后再次答错，题目会重新回到错题本。
class ErrorBookManageScreen extends StatefulWidget {
  const ErrorBookManageScreen({
    super.key,
    required this.mode,
    this.bankIds,
  });

  /// 错题筛选口径：all / wrong / bookmark（与错题本筛选栏一致）
  final String mode;

  /// 已选题库（null / 空 = 全库）
  final Set<int>? bankIds;

  @override
  State<ErrorBookManageScreen> createState() => _ErrorBookManageScreenState();
}

typedef _ErrorItem = ({
  Question question,
  int answered,
  int correct,
  FSRSCardState? card
});

class _ErrorBookManageScreenState extends State<ErrorBookManageScreen> {
  List<_ErrorItem>? _items;
  bool _loading = true;
  final Set<int> _selected = {};
  bool _removing = false;

  String get _modeLabel => switch (widget.mode) {
        'wrong' => '到期错题',
        'bookmark' => '收藏题目',
        _ => '全部错题',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final appState = context.read<AppState>();
      final items = await appState.getErrorQuestionCards(widget.mode,
          bankIds: widget.bankIds);
      if (!mounted) return;
      setState(() {
        // 没有 id 的题无法精确定位，直接排除（正常不会出现）
        _items = items.where((e) => e.question.id != null).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = [];
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载错题失败：$e')),
      );
    }
  }

  void _toggle(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleAll() {
    final ids =
        (_items ?? const <_ErrorItem>[]).map((e) => e.question.id!).toSet();
    setState(() {
      if (_selected.length == ids.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(ids);
      }
    });
  }

  Future<void> _remove() async {
    if (_selected.isEmpty || _removing) return;
    final appState = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final count = _selected.length;
    final ok = await NatsumeDialog.show<bool>(
      context,
      title: '从错题本移除？',
      content: Text('这 $count 道题会从错题本移除，题库里的题目与作答记录都保留；'
          '以后再次答错还会回到错题本。'),
      actions: [
        NatsumeButton(
          label: '取消',
          kind: NatsumeButtonKind.secondary,
          dense: true,
          onPressed: () => Navigator.pop(context, false),
        ),
        NatsumeButton(
          label: '移除',
          kind: NatsumeButtonKind.danger,
          dense: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (ok != true || !mounted) return;

    setState(() => _removing = true);
    try {
      final removed = await appState.removeQuestionsFromErrorBook(_selected);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('已从错题本移除 $removed 道题')),
      );
      nav.pop(removed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _removing = false);
      messenger.showSnackBar(SnackBar(content: Text('移除失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final items = _items ?? const <_ErrorItem>[];
    final allSelected = items.isNotEmpty && _selected.length == items.length;

    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: Text('管理$_modeLabel'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: _removing ? null : _toggleAll,
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
        ],
      ),
      body: ResponsivePage(
        child: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NatsumeSkeleton(width: 180),
                    SizedBox(height: NatsumeSpace.sm),
                    NatsumeSkeleton(width: 120),
                  ],
                ),
              )
            : items.isEmpty
                ? const NatsumeEmptyState(
                    icon: Icons.check_circle_outline,
                    title: '当前范围没有可移除的错题',
                    description: '错题本里的题目都在这里，没有可删减的内容。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(NatsumeSpace.md),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final it = items[i];
                      final id = it.question.id!;
                      final checked = _selected.contains(id);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
                        child: NatsumeSurface(
                          onTap: _removing ? null : () => _toggle(id),
                          padding: const EdgeInsets.symmetric(
                              horizontal: NatsumeSpace.sm,
                              vertical: NatsumeSpace.xs),
                          child: Row(
                            children: [
                              Checkbox(
                                value: checked,
                                onChanged:
                                    _removing ? null : (_) => _toggle(id),
                                visualDensity: VisualDensity.compact,
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${i + 1}. ${stripImageTokens(it.question.title)}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: NatsumeType.body,
                                          color: ac.textPrimary),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _statLine(it),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: NatsumeType.caption,
                                          color: ac.textSecondary),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
      bottomNavigationBar: _loading || items.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(NatsumeSpace.md,
                    NatsumeSpace.sm, NatsumeSpace.md, NatsumeSpace.md),
                decoration: BoxDecoration(
                  color: ac.background,
                  border: Border(
                      top: BorderSide(
                          color: ac.border, width: NatsumeLine.width)),
                ),
                child: NatsumeButton(
                  label: _selected.isEmpty
                      ? '从错题本移除'
                      : '从错题本移除（${_selected.length}）',
                  kind: NatsumeButtonKind.danger,
                  icon: Icons.playlist_remove,
                  expand: true,
                  onPressed: _selected.isEmpty || _removing ? null : _remove,
                ),
              ),
            ),
    );
  }

  /// 逐题一行统计：做过 N 次 · 正确率 P% · 下次复习：X
  /// （与错题本主列表同一句式，用户不用重新理解一套口径）
  String _statLine(_ErrorItem it) {
    final parts = <String>['做过 ${it.answered} 次'];
    if (it.answered > 0) {
      parts.add(
          '正确率 ${(it.correct / it.answered * 100).toStringAsFixed(0)}%');
    }
    final card = it.card;
    if (card != null) {
      parts.add('下次复习：${relativeDayLabel(card.nextReviewAt)}');
    }
    return parts.join(' · ');
  }
}

