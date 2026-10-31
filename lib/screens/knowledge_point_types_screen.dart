import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

/// 「知识点体系」编辑页（v1.35）。
///
/// AI 打的知识点标签五花八门（同一章变成「呼吸系统」「肺炎」
/// 「呼吸系统疾病」好几个），错题本按知识点分组就散了。这个页面让用户
/// **自己定义一套口径**：条目、顺序都由他说了算，保存后：
///   · 导入解析时把清单塞进提示词，AI 只能从里面挑；
///   · 「为剩余题目打标签」按同一个清单收敛；
///   · 「一键重导知识点」把已有题目全部重打一遍。
///
/// 空列表 = 交回 AI 自行判断（旧行为），所以清空是合法的「恢复默认」。
class KnowledgePointTypesScreen extends StatefulWidget {
  const KnowledgePointTypesScreen({super.key});

  @override
  State<KnowledgePointTypesScreen> createState() =>
      _KnowledgePointTypesScreenState();
}

class _KnowledgePointTypesScreenState extends State<KnowledgePointTypesScreen> {
  /// 单个知识点名称长度上限（比 AI 提示词里的「10 字以内」放宽一点）
  static const int _maxNameLength = 20;

  late List<String> _types;
  final TextEditingController _ctrl = TextEditingController();
  bool _saving = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _types = List<String>.of(
        context.read<AppState>().settings.knowledgePointTypes);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<String> get _saved =>
      context.read<AppState>().settings.knowledgePointTypes;

  /// 是否有未保存的改动（含顺序变化）
  bool get _dirty {
    final saved = _saved;
    if (saved.length != _types.length) return true;
    for (var i = 0; i < saved.length; i++) {
      if (saved[i] != _types[i]) return true;
    }
    return false;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _add(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return;
    if (name.length > _maxNameLength) {
      _toast('单个知识点请控制在 $_maxNameLength 字以内');
      return;
    }
    if (_types.any((t) => t.toLowerCase() == name.toLowerCase())) {
      _toast('「$name」已经在体系里了');
      return;
    }
    setState(() {
      _types = [..._types, name];
      _ctrl.clear();
    });
  }

  void _remove(int index) {
    setState(() => _types = [..._types]..removeAt(index));
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _types.length) return;
    setState(() {
      final next = [..._types];
      final tmp = next[index];
      next[index] = next[target];
      next[target] = tmp;
      _types = next;
    });
  }

  /// 把库里已存在的标签一键收编（去重、保持已有顺序）
  Future<void> _importExisting() async {
    if (_importing) return;
    setState(() => _importing = true);
    List<String> existing;
    try {
      existing = await context.read<AppState>().getDistinctKnowledgePoints();
    } catch (_) {
      existing = const [];
    }
    if (!mounted) return;
    final merged = [..._types];
    var added = 0;
    for (final kp in existing) {
      if (merged.any((t) => t.toLowerCase() == kp.toLowerCase())) continue;
      merged.add(kp);
      added++;
    }
    setState(() {
      _types = merged;
      _importing = false;
    });
    _toast(existing.isEmpty
        ? '题库里还没有打标签的题目'
        : added == 0
            ? '题库里现有标签都已在体系里'
            : '已收编 $added 个现有标签');
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    // 先同步取 messenger，避免 await 之后跨异步使用 context
    final messenger = ScaffoldMessenger.of(context);
    await context.read<AppState>().setKnowledgePointTypes(_types);
    if (!mounted) return;
    setState(() => _saving = false);
    messenger.showSnackBar(SnackBar(
      content: Text(_types.isEmpty
          ? '已清空知识点体系，AI 会自行判断'
          : '知识点体系已保存（${_types.length} 类）'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 先同步取 Navigator，避免 await 之后跨异步使用 context
        final navigator = Navigator.of(context);
        final danger = AppThemeColors.of(context).danger;
        final leave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('知识点体系还没保存'),
            content: const Text('离开后这次修改会丢失，确定要离开吗？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('继续编辑')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('离开', style: TextStyle(color: danger)),
              ),
            ],
          ),
        );
        if (leave == true && mounted) navigator.pop();
      },
      child: Scaffold(
        backgroundColor: ac.background,
        appBar: AppBar(title: const Text('知识点体系')),
        body: ResponsivePage(
          child: ListView(
            padding: const EdgeInsets.all(NatsumeSpace.md),
            children: [
              _introSection(ac),
              const SizedBox(height: NatsumeSpace.md),
              _addSection(ac),
              const SizedBox(height: NatsumeSpace.md),
              _listSection(ac),
              const SizedBox(height: NatsumeSpace.md),
              NatsumeButton(
                label: _saving ? '保存中…' : '保存知识点体系',
                icon: Icons.check_rounded,
                expand: true,
                onPressed: (_saving || !_dirty) ? null : _save,
              ),
              const SizedBox(height: NatsumeSpace.md),
              Text(
                '不设体系时 AI 自己起名（同一章可能被打成好几种写法）；'
                '设了体系后，导入解析、打标签、一键重导都只在这套口径里选，'
                '错题本按知识点分组才会整齐。',
                style: NatsumeType.microStyle
                    .copyWith(color: ac.textTertiary, height: 1.6),
              ),
              const SizedBox(height: NatsumeSpace.lg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _introSection(AppThemeColors ac) {
    return NatsumeSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.category_outlined, size: 18, color: ac.accent),
              const SizedBox(width: NatsumeSpace.xs),
              Expanded(
                child: Text('什么是知识点体系',
                    style:
                        NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
              ),
              Text('${_types.length} 类',
                  style: NatsumeType.microStyle.copyWith(
                      color: ac.textTertiary,
                      fontFeatures: NatsumeType.tabular)),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xs),
          Text(
            '就是你自己定的知识点清单，比如「呼吸系统 / 循环系统 / 药理」。'
            '顺序即优先级，AI 会优先贴着前面的条目归类。',
            style: NatsumeType.captionStyle
                .copyWith(color: ac.textSecondary, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _addSection(AppThemeColors ac) {
    return NatsumeSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('新增知识点',
              style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
          const SizedBox(height: NatsumeSpace.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  textInputAction: TextInputAction.done,
                  onSubmitted: _add,
                  style: NatsumeType.bodyStyle.copyWith(color: ac.textPrimary),
                  decoration: InputDecoration(
                    hintText: '如：呼吸系统',
                    hintStyle:
                        NatsumeType.bodyStyle.copyWith(color: ac.textTertiary),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: NatsumeSpace.xs),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加'),
                onPressed: () => _add(_ctrl.text),
              ),
            ],
          ),
          const SizedBox(height: NatsumeSpace.sm),
          Wrap(
            spacing: NatsumeSpace.xs,
            runSpacing: NatsumeSpace.xs,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.playlist_add_rounded, size: 16),
                label: Text(_importing ? '读取中…' : '收编题库现有标签'),
                onPressed: _importing ? null : _importExisting,
              ),
              if (_types.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.clear_all_rounded, size: 16),
                  label: const Text('清空（交回 AI 判断）'),
                  onPressed: () => setState(() => _types = <String>[]),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _listSection(AppThemeColors ac) {
    return NatsumeSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('体系条目',
              style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
          const SizedBox(height: NatsumeSpace.xxs),
          Text(
            _types.isEmpty ? '还没有条目：AI 会自行判断知识点。' : '可上下移动调整优先级，右侧删除。',
            style: NatsumeType.microStyle
                .copyWith(color: ac.textTertiary, height: 1.5),
          ),
          const SizedBox(height: NatsumeSpace.sm),
          if (_types.isEmpty)
            Text('（空）',
                style: NatsumeType.bodyStyle.copyWith(color: ac.textTertiary))
          else
            for (var i = 0; i < _types.length; i++) ...[
              _tile(ac, i),
              if (i != _types.length - 1)
                const SizedBox(height: NatsumeSpace.xs),
            ],
        ],
      ),
    );
  }

  Widget _tile(AppThemeColors ac, int index) {
    final name = _types[index];
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xxs),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text('${index + 1}',
                style: NatsumeType.microStyle.copyWith(
                    color: ac.textTertiary,
                    fontFeatures: NatsumeType.tabular)),
          ),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NatsumeType.bodyStyle.copyWith(color: ac.textPrimary)),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            tooltip: '上移',
            visualDensity: VisualDensity.compact,
            onPressed: index == 0 ? null : () => _move(index, -1),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward_rounded, size: 18),
            tooltip: '下移',
            visualDensity: VisualDensity.compact,
            onPressed:
                index == _types.length - 1 ? null : () => _move(index, 1),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 18, color: ac.danger),
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            onPressed: () => _remove(index),
          ),
        ],
      ),
    );
  }
}
