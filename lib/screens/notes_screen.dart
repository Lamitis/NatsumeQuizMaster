import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../models/plugin_sync_scope.dart';
import '../services/app_state.dart';
import '../services/notes/notes_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/note_graph_view.dart';
import 'note_editor_screen.dart';

/// 笔记（v1.31 · 笔记插件）——「我的 → 学习工具 → 双链笔记」的落点。
///
/// 用户要求：
/// - 笔记**按题库名称分类**（每个题库一节）；
/// - 支持 `[[双链]]` 与 Graph 图谱（取形 Logseq）；
/// - 能在这里编辑、修改、删除；
/// - 刷题看解析时也能随手写（入口在答题页解析卡）。
///
/// 同步边界：笔记不参与局域网同步（插件数据不在同步导出清单里），
/// 页面顶部写着同步状态（v1.35：跟着「插件内容同步」开关走，开 / 关都明说），
/// 避免换机后发现笔记没有。
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _searchCtrl = TextEditingController();

  List<NoteGroup> _groups = const [];
  NoteGraph _graph = NoteGraph.empty;
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = NotesService.instance;
    final groups = await service.groups(query: _query);
    final graph = await service.graph();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _graph = graph;
      _loading = false;
    });
  }

  Future<void> _edit(Note? note,
      {int? bankId, int? questionId, String? title}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(
          note: note,
          bankId: bankId,
          questionId: questionId,
          initialTitle: title,
        ),
      ),
    );
    await _load();
  }

  /// 图谱里点节点：已有这一页就打开，没有就新建（Logseq 的悬空页行为）
  Future<void> _openNode(NoteNode node) async {
    final notes = await NotesService.instance.list();
    Note? hit;
    for (final n in notes) {
      if (n.title.trim() == node.id.trim()) {
        hit = n;
        break;
      }
    }
    if (!mounted) return;
    await _edit(hit, title: hit == null ? node.id : null);
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final appState = context.watch<AppState>();
    final enabled = appState.notesPluginEnabled;
    // v1.35：同步开关决定顶部提示（默认开）
    final syncOn =
        appState.isPluginSyncEnabled(PluginSyncScope.notesPluginId);
    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('双链笔记'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '笔记'),
            Tab(text: '图谱'),
          ],
        ),
        actions: [
          NatsumeIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onPressed: _load,
          ),
          const SizedBox(width: NatsumeSpace.xxs),
        ],
      ),
      body: ResponsivePage(
        child: Column(
          children: [
            if (!enabled) _buildDisabledBanner(ac),
            _buildSyncBanner(ac, syncOn),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildNotesTab(ac),
                  _buildGraphTab(ac),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('新建笔记'),
            ),
    );
  }

  /// 同步提示（v1.35）：开 / 关都说清楚，不能一律写「无法同步」
  Widget _buildSyncBanner(AppThemeColors ac, bool syncOn) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, 0),
      child: NatsumeSurface(
        tone: NatsumeTone.alt,
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
        child: Row(
          children: [
            Icon(syncOn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 16, color: syncOn ? ac.success : ac.warning),
            const SizedBox(width: NatsumeSpace.xs),
            Expanded(
              child: Text(
                syncOn
                    ? NotesService.syncNotice
                    : '已关闭笔记同步：换设备不跟随，请用「备份与恢复」',
                style: NatsumeType.microStyle.copyWith(color: ac.textSecondary),
              ),
            ),
            NatsumeTag(
              syncOn ? '随局域网同步' : '仅本机',
              tone: syncOn ? NatsumeTagTone.success : NatsumeTagTone.warning,
            ),
          ],
        ),
      ),
    );
  }

  // ════════════════════ 笔记列表（按题库分类） ════════════════════

  Widget _buildNotesTab(AppThemeColors ac) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, 0),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索笔记标题 / 正文',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                        _load();
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) {
              setState(() => _query = v);
              _load();
            },
          ),
        ),
        Expanded(
          child: _groups.isEmpty
              ? NatsumeEmptyState(
                  icon: Icons.sticky_note_2_outlined,
                  title: _query.isEmpty ? '还没有笔记' : '没有匹配的笔记',
                  description: _query.isEmpty
                      ? '刷题看解析时点「写笔记」，或在这里直接新建；用 [[页面名]] 连起来'
                      : '换个关键词试试',
                  action: _query.isEmpty
                      ? NatsumeButton(
                          label: '新建笔记',
                          icon: Icons.edit_outlined,
                          onPressed: () => _edit(null),
                        )
                      : null,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(NatsumeSpace.md,
                      NatsumeSpace.sm, NatsumeSpace.md, 96),
                  children: [
                    for (final g in _groups) ..._buildGroup(ac, g),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _buildGroup(AppThemeColors ac, NoteGroup group) {
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
        child: NatsumeSectionHeader(
          title: group.bankName,
          subtitle: '${group.notes.length} 条笔记',
        ),
      ),
      for (final n in group.notes) ...[
        NatsumeSurface(
          onTap: () => _edit(n),
          padding: const EdgeInsets.symmetric(
              horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(n.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NatsumeType.bodyStyle.copyWith(
                            color: ac.textPrimary,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: NatsumeSpace.xxs),
                  if (n.targets.isNotEmpty)
                    NatsumeTag('${n.targets.length} 链',
                        tone: NatsumeTagTone.accent),
                  if (n.questionId != null)
                    const Padding(
                      padding: EdgeInsets.only(left: NatsumeSpace.xxs),
                      child: NatsumeTag('题目'),
                    ),
                ],
              ),
              if (n.excerpt.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(n.excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textSecondary)),
              ],
              const SizedBox(height: 2),
              Text('更新 ${_fmtDate(n.updatedAt)}',
                  style:
                      NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
            ],
          ),
        ),
        const SizedBox(height: NatsumeSpace.xxs),
      ],
      const SizedBox(height: NatsumeSpace.sm),
    ];
  }

  // ════════════════════ 图谱 ════════════════════

  Widget _buildGraphTab(AppThemeColors ac) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.all(NatsumeSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_graph.nodes.length} 个页面 · ${_graph.edges.length} 条链接',
            style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary),
          ),
          const SizedBox(height: NatsumeSpace.xs),
          Expanded(
            child: NoteGraphView(graph: _graph, onTapNode: _openNode),
          ),
          const SizedBox(height: NatsumeSpace.xs),
          Text('实心点 = 已写过的笔记，空心点 = 只被引用过的悬空页（点一下即可新建）',
              style: NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
        ],
      ),
    );
  }

  /// '2026-10-29T13:05:00.000' → '2026-10-29 13:05'
  static String _fmtDate(String iso) {
    if (iso.length < 16) return iso;
    return iso.substring(0, 16).replaceFirst('T', ' ');
  }

  Widget _buildDisabledBanner(AppThemeColors ac) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, 0),
      child: NatsumeSurface(
        tone: NatsumeTone.alt,
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
        child: Row(
          children: [
            Icon(Icons.extension_off_outlined, size: 16, color: ac.danger),
            const SizedBox(width: NatsumeSpace.xs),
            Expanded(
              child: Text('笔记插件已停用，可在「世界总览 → 插件」重新启用',
                  style:
                      NatsumeType.microStyle.copyWith(color: ac.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
