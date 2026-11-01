import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/plugin.dart';
import '../models/plugin_sort.dart';
import '../services/plugins/plugin_loader.dart';
import '../services/plugins/plugin_prompt_service.dart';
import '../services/plugins/plugin_registry.dart';
import '../services/plugins/plugin_stats_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/plugin_install_flow.dart';
import 'plugin_detail_screen.dart';

/// 拉表函数（测试注入，避免真联网）
typedef RegistryFetcher = Future<RegistrySnapshot> Function();

/// 安装函数（测试注入：抛 [PluginRegistryException] 就能验证失败兜底 UI）
typedef RegistryInstaller = Future<PluginInstallResult> Function(
    RegistryPlugin entry);

/// 状态筛选的内部值（界面显示中文，值只在本文件里流转）
const String _filterAll = 'all';
const String _filterInstallable = 'install';
const String _filterUpdate = 'update';
const String _filterInstalled = 'installed';

/// 插件市场（v1.36）。
///
/// 与「世界总览 → 插件」的分工：
/// - **本页负责发现**：拉登记表、搜索 / 分类 / 状态筛选、看仓库与更新日志、
///   安装与更新、以及本地 zip 兜底安装；
/// - **世界总览负责治理**：已装插件的启停、卸载与署名说明。
///
/// 三条约定（与 [PluginRegistryService] 一致）：
/// 1. 拉表失败**不清空**已有列表，只在顶部提示「这次没拉到」；
/// 2. 安装必须由用户点确认；来源说明只弹一次，之后不再打扰；
/// 3. 全部镜像都失败时，把**原始**下载地址交给用户（复制 / 浏览器下载后
///    走「从本地文件安装」），而不是让用户干瞪眼。
class PluginMarketScreen extends StatefulWidget {
  const PluginMarketScreen({
    super.key,
    this.fetcher,
    this.installer,
    this.statsLoader,
  });

  /// 缺省走 [PluginRegistryService.instance.fetch]
  final RegistryFetcher? fetcher;

  /// 缺省走 [PluginRegistryService.instance.install]
  final RegistryInstaller? installer;

  /// 缺省走 [PluginStatsService.instance.load]（下载量 / 版本历史）
  final PluginStatsBatchLoader? statsLoader;

  @override
  State<PluginMarketScreen> createState() => _PluginMarketScreenState();
}

class _PluginMarketScreenState extends State<PluginMarketScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// null = 还没成功拉到过；拉表失败时保留上一次的快照
  RegistrySnapshot? _snapshot;
  Map<String, PluginInfo> _installed = {};
  bool _loading = false;
  String? _error;

  String _query = '';
  String? _category; // null = 全部分类
  String _filter = _filterAll;

  /// 排序方式（v1.36）：默认沿用登记表原顺序，用户切了才变
  PluginSortMode _sort = PluginSortMode.registry;

  /// GitHub 统计（下载量 / 版本历史）：拿不到就是没数字，不影响列表
  Map<String, PluginStats> _stats = {};
  bool _statsLoading = false;

  /// 统计没拉全的原因（一行小字，不弹窗）
  String? _statsNote;

  /// 正在安装的插件 id（按钮转圈，防重复点）
  final Set<String> _busy = {};

  /// 本地安装进行中（选文件 + 解包），防连点
  bool _localBusy = false;

  /// 安装流程与详情页共用：来源说明 / 确认弹窗 / 失败兜底只有一份实现
  late final PluginInstallFlow _flow = PluginInstallFlow(
    install: widget.installer ?? PluginRegistryService.instance.install,
    onInstallFromFile: _installFromFile,
  );

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<RegistrySnapshot> _doFetch() =>
      (widget.fetcher ?? PluginRegistryService.instance.fetch)();

  /// 拉表：失败只提示，不清空 [_snapshot]。统计随后单独拉，失败不影响列表。
  Future<void> _refresh({bool forceStats = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await _doFetch();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
      _pruneCategoryFilter();
      await _loadInstalled();
      await _loadStats(force: forceStats);
    } on PluginRegistryException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '插件表读取失败：$e';
      });
    }
  }

  /// 下载量 / 版本历史：一天缓存命中就不联网（见 [PluginStatsService]）。
  ///
  /// 这里**永远不抛**：统计只是锦上添花，失败就少一行数字，绝不挡住浏览与安装。
  Future<void> _loadStats({bool force = false}) async {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.plugins.isEmpty || _statsLoading) return;
    setState(() {
      _statsLoading = true;
      if (force) _statsNote = null;
    });
    try {
      final loader = widget.statsLoader ?? PluginStatsService.instance.load;
      final result = await loader(snapshot.plugins, forceRefresh: force);
      if (!mounted) return;
      setState(() {
        _stats = {..._stats, ...result.byPluginId};
        if (result.rateLimited) {
          _statsNote = 'GitHub API 限额了，下载量先按本地缓存显示';
        } else if (result.failure != null) {
          _statsNote = result.failure;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statsNote = '下载量没拉到：$e');
    } finally {
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  /// 已装插件只用来判断「已安装 / 可更新」；读失败不该挡住浏览，
  /// 但要看得出差别，所以把错误并进顶部提示。
  Future<void> _loadInstalled() async {
    try {
      final map = await PluginRegistryService.instance.installedMap();
      // v1.37：装 / 更新 / 卸载之后重新读一次插件提示词（AI 侧只读内存快照）
      await PluginPromptService.instance.refresh(installed: map.values.toList());
      if (!mounted) return;
      setState(() => _installed = map);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error ??= '读取已安装列表失败：$e');
    }
  }

  String _actionFor(RegistryPlugin entry) =>
      PluginRegistryService.actionFor(entry, _installed[entry.id]);

  /// 分类 → 条目数（按名字排序，侧边栏与胶囊条共用）。
  ///
  /// v1.36 起改成「按名字排」而不是「条目多的在前」：分类栏是导航，
  /// 位置固定才记得住；数量用数字显示，不用排序表达。
  Map<String, int> get _categoryCounts {
    final counts = <String, int>{};
    for (final e in _snapshot?.plugins ?? const <RegistryPlugin>[]) {
      counts.update(e.categoryLabel, (v) => v + 1, ifAbsent: () => 1);
    }
    final names = counts.keys.toList()..sort();
    return {for (final name in names) name: counts[name]!};
  }

  /// 出现过的分类；只有一个分类时不显示筛选栏
  List<String> get _categories => _categoryCounts.keys.toList();

  /// 分类筛选是**跟着数据走**的（见 [_categoryCounts]），所以刷新后某一类可能整类消失
  /// （作者改了分类、插件下架、换了一张登记表）。
  ///
  /// 这时如果还锁着旧分类，列表会一直是空的，而顶部又看不到那一项（只剩一个分类时
  /// 筛选栏整体隐藏），用户连「怎么退回去」都找不到——所以这里自动回到「全部分类」。
  void _pruneCategoryFilter() {
    final selected = _category;
    if (selected == null) return;
    if (_categoryCounts.containsKey(selected)) return;
    setState(() => _category = null);
  }

  List<RegistryPlugin> get _visible {
    final entries = _snapshot?.plugins ?? const <RegistryPlugin>[];
    final filtered = entries.where((e) {
      if (_category != null && e.categoryLabel != _category) return false;
      if (!e.matchesQuery(_query)) return false;
      switch (_filter) {
        case _filterInstallable:
          return _actionFor(e) == 'install';
        case _filterUpdate:
          return _actionFor(e) == 'update';
        case _filterInstalled:
          return _actionFor(e) == 'installed';
        default:
          return true;
      }
    }).toList();
    return sortRegistryPlugins(filtered, _sort, _stats);
  }

  bool get _hasFilter =>
      _query.trim().isNotEmpty || _category != null || _filter != _filterAll;

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _category = null;
      _filter = _filterAll;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件市场'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: '从本地文件安装',
            onPressed: _localBusy ? null : _installFromFile,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新插件表',
            onPressed: _loading ? null : () => _refresh(forceStats: true),
          ),
        ],
      ),
      body: ResponsivePage(
        child: isWideLayout(context) ? _wideBody(ac) : _mainList(ac),
      ),
    );
  }

  /// 宽屏（≥840dp）：左侧分类栏常驻，右侧照旧单列（限宽由 [ResponsivePage] 管）
  Widget _wideBody(AppThemeColors ac) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: NatsumeSpace.md),
        _sidebar(ac),
        Expanded(child: _mainList(ac, showCategoryBar: false)),
      ],
    );
  }

  Widget _mainList(AppThemeColors ac, {bool showCategoryBar = true}) {
    return ListView(
      padding: const EdgeInsets.all(NatsumeSpace.md),
      children: [
        _header(ac),
        const SizedBox(height: NatsumeSpace.sm),
        _searchBar(ac),
        // 宽屏的分类在左侧栏里，胶囊条就不再重复一遍
        if (showCategoryBar && _categories.length > 1) ...[
          const SizedBox(height: NatsumeSpace.xs),
          _categoryBar(),
        ],
        const SizedBox(height: NatsumeSpace.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _statusBar(ac)),
            const SizedBox(width: NatsumeSpace.xxs),
            _sortMenu(ac),
          ],
        ),
        if (_statsLoading || _statsNote != null) ...[
          const SizedBox(height: NatsumeSpace.xxs),
          Text(
            _statsLoading ? '正在读取下载量…' : '下载量：${_statsNote!}',
            style: NatsumeType.microStyle
                .copyWith(color: ac.textTertiary, height: 1.4),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: NatsumeSpace.xs),
          _errorBanner(ac),
        ],
        const SizedBox(height: NatsumeSpace.sm),
        ..._content(ac),
        const SizedBox(height: NatsumeSpace.lg),
      ],
    );
  }

  // ── 顶部分区 ──

  Widget _header(AppThemeColors ac) {
    final snapshot = _snapshot;
    final total = snapshot?.plugins.length ?? 0;
    final subtitle = snapshot == null
        ? 'Natsume-Registry：只登记信息，不审核、不托管插件文件'
        : 'Natsume-Registry · $total 个插件'
            '${snapshot.droppedCount > 0 ? '（另有 ${snapshot.droppedCount} 条不合规被丢弃）' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NatsumeSectionHeader(
          title: '插件市场',
          subtitle: subtitle,
          trailing: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        // disclaimer 必须看得见（登记 ≠ 审核），列表旁常驻一行小字
        if (snapshot != null && snapshot.disclaimer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: NatsumeSpace.xxs),
            child: Text(
              snapshot.disclaimer,
              style: NatsumeType.microStyle
                  .copyWith(color: ac.textTertiary, height: 1.5),
            ),
          ),
        if (snapshot != null && snapshot.generatedAt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: NatsumeSpace.xxs),
            child: Text(
              '表生成于 ${snapshot.generatedAt}',
              style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
            ),
          ),
      ],
    );
  }

  Widget _searchBar(AppThemeColors ac) {
    return TextField(
      controller: _searchController,
      onChanged: (v) => setState(() => _query = v),
      textInputAction: TextInputAction.search,
      style: NatsumeType.bodyStyle.copyWith(color: ac.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索插件名 / 作者 / 分类 / 标签',
        hintStyle: NatsumeType.bodyStyle.copyWith(color: ac.textTertiary),
        prefixIcon: const Icon(Icons.search_rounded, size: 18),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                tooltip: '清除搜索',
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
        border: const OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: ac.accent, width: NatsumeLine.width),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm,
          vertical: NatsumeSpace.xs,
        ),
      ),
    );
  }

  Widget _categoryBar() {
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          NatsumeChip(
            label: '全部分类',
            dense: true,
            selected: _category == null,
            onTap: () => setState(() => _category = null),
          ),
          for (final c in _categories) ...[
            const SizedBox(width: NatsumeSpace.xxs),
            NatsumeChip(
              label: c,
              dense: true,
              selected: _category == c,
              onTap: () => setState(() => _category = _category == c ? null : c),
            ),
          ],
        ],
      ),
    );
  }

  /// 排序下拉（v1.36）：只影响当前列表顺序，不改登记表也不改已装状态
  Widget _sortMenu(AppThemeColors ac) {
    return PopupMenuButton<PluginSortMode>(
      tooltip: '排序方式',
      initialValue: _sort,
      onSelected: (mode) => setState(() => _sort = mode),
      itemBuilder: (context) => [
        for (final mode in PluginSortMode.values)
          PopupMenuItem<PluginSortMode>(
            value: mode,
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: mode == _sort
                      ? Icon(Icons.check_rounded, size: 14, color: ac.accent)
                      : null,
                ),
                const SizedBox(width: NatsumeSpace.xxs),
                Text(mode.label,
                    style: NatsumeType.captionStyle.copyWith(
                        color: mode == _sort ? ac.accent : ac.textPrimary)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.xxs, vertical: NatsumeSpace.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert_rounded, size: 14, color: ac.textSecondary),
            const SizedBox(width: 2),
            Text(_sort.label,
                style: NatsumeType.microStyle.copyWith(color: ac.textSecondary)),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: ac.textSecondary),
          ],
        ),
      ),
    );
  }

  /// 宽屏左侧分类栏：常驻、带条目数，点一下就地筛选（再点同一个回到全部）
  Widget _sidebar(AppThemeColors ac) {
    final counts = _categoryCounts;
    final total = _snapshot?.plugins.length ?? 0;
    return SizedBox(
      width: 168,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: NatsumeSpace.md),
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: NatsumeSpace.xs, bottom: NatsumeSpace.xxs),
            child: Text('分类',
                style: NatsumeType.eyebrowStyle
                    .copyWith(color: ac.textTertiary)),
          ),
          _sidebarTile(
            ac,
            tileKey: const ValueKey('plugin-sidebar-all'),
            label: '全部分类',
            count: total,
            selected: _category == null,
            onTap: () => setState(() => _category = null),
          ),
          for (final entry in counts.entries)
            _sidebarTile(
              ac,
              tileKey: ValueKey('plugin-sidebar-${entry.key}'),
              label: entry.key,
              count: entry.value,
              selected: _category == entry.key,
              onTap: () => setState(
                  () => _category = _category == entry.key ? null : entry.key),
            ),
        ],
      ),
    );
  }

  Widget _sidebarTile(
    AppThemeColors ac, {
    required Key tileKey,
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        key: tileKey,
        color: selected ? ac.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(NatsumeRadius.small),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NatsumeRadius.small),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: NatsumeSpace.xs, vertical: NatsumeSpace.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.captionStyle.copyWith(
                      color: selected ? ac.accent : ac.textSecondary,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: NatsumeSpace.xxs),
                Text('$count',
                    style: NatsumeType.microStyle.copyWith(
                        color: selected ? ac.accent : ac.textTertiary)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusBar(AppThemeColors ac) {
    const entries = <(String, String)>[
      (_filterAll, '全部'),
      (_filterInstallable, '未安装'),
      (_filterUpdate, '可更新'),
      (_filterInstalled, '已安装'),
    ];
    return Wrap(
      spacing: NatsumeSpace.xxs,
      runSpacing: NatsumeSpace.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final e in entries)
          NatsumeChip(
            label: e.$2,
            dense: true,
            selected: _filter == e.$1,
            onTap: () => setState(() => _filter = e.$1),
          ),
        if (_hasFilter)
          TextButton(
            onPressed: _clearFilters,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: NatsumeSpace.xs),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '清除筛选',
              style: NatsumeType.microStyle.copyWith(color: ac.accent),
            ),
          ),
      ],
    );
  }

  Widget _errorBanner(AppThemeColors ac) {
    return NatsumeSurface(
      padding: const EdgeInsets.all(NatsumeSpace.xs),
      tone: NatsumeTone.alt,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NatsumeTag('本次没拉到', tone: NatsumeTagTone.warning),
          const SizedBox(width: NatsumeSpace.xs),
          Expanded(
            child: Text(
              // 拉表失败只提示，列表保持上一次的内容
              '${_error!}${(_snapshot?.plugins.isEmpty ?? true) ? '' : '（下面是上次的结果）'}',
              style: NatsumeType.microStyle
                  .copyWith(color: ac.textSecondary, height: 1.4),
            ),
          ),
          NatsumeButton(
            label: '重试',
            dense: true,
            kind: NatsumeButtonKind.ghost,
            onPressed: _refresh,
          ),
        ],
      ),
    );
  }

  // ── 列表内容 ──

  List<Widget> _content(AppThemeColors ac) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      if (_loading) {
        return const [
          NatsumeEmptyState(
            icon: Icons.cloud_download_outlined,
            title: '正在读取插件表',
            description: '首次读取需要联网；失败时不会影响已安装插件',
          ),
        ];
      }
      return [
        NatsumeEmptyState(
          icon: Icons.storefront_outlined,
          title: '这次没能读到插件表',
          description: '检查网络，或到「设置 → 网络加速」换个镜像；'
              '也可以用浏览器手动下载插件包，再点右上角「从本地文件安装」',
          action: NatsumeButton(
            label: '重试',
            dense: true,
            icon: Icons.refresh_rounded,
            onPressed: _refresh,
          ),
        ),
      ];
    }
    final visible = _visible;
    if (visible.isEmpty) {
      final filtered = snapshot.plugins.isNotEmpty;
      return [
        NatsumeEmptyState(
          icon: filtered
              ? Icons.filter_alt_off_outlined
              : Icons.storefront_outlined,
          title: filtered ? '没有匹配的插件' : '登记表里还没有插件',
          description: filtered
              ? '换个关键词，或放宽分类 / 状态筛选'
              : '表是空的（count = 0），不是加载失败；作者提交 PR 后会自动进表',
          action: filtered
              ? NatsumeButton(
                  label: '清除筛选',
                  dense: true,
                  kind: NatsumeButtonKind.secondary,
                  onPressed: _clearFilters,
                )
              : null,
        ),
      ];
    }
    return [
      for (final entry in visible) ...[
        _card(ac, entry),
        const SizedBox(height: NatsumeSpace.xs),
      ],
    ];
  }

  // ── 单个插件 ──

  Widget _card(AppThemeColors ac, RegistryPlugin entry) {
    final installed = _installed[entry.id];
    final action = _actionFor(entry);
    final busy = _busy.contains(entry.id);
    final stats = _stats[entry.id];
    return NatsumeSurface(
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      // 点卡片进详情：安装按钮仍在卡片里，点按钮不会误触卡片（按钮吃掉手势）
      onTap: () => _openDetail(entry),
      semanticLabel: '${entry.name}，查看详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NatsumeType.h3Style.copyWith(
                      fontWeight: FontWeight.w600, color: ac.textPrimary),
                ),
              ),
              const SizedBox(width: NatsumeSpace.xs),
              Text('v${entry.version}',
                  style: NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
              if (installed != null) ...[
                const SizedBox(width: NatsumeSpace.xs),
                NatsumeTag(
                  action == 'update' ? '可更新' : '已安装',
                  tone: action == 'update'
                      ? NatsumeTagTone.warning
                      : NatsumeTagTone.success,
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: Text(
                  'by ${entry.author}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      NatsumeType.microStyle.copyWith(color: ac.textTertiary),
                ),
              ),
              const SizedBox(width: NatsumeSpace.xs),
              // 分类用描边标签：和上面的状态标签（实心）区分开
              NatsumeTag(entry.categoryLabel, filled: false),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xxs),
          Text(entry.description,
              style:
                  NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
          if (entry.tags.isNotEmpty) ...[
            const SizedBox(height: NatsumeSpace.xs),
            Wrap(
              spacing: NatsumeSpace.xxs,
              runSpacing: NatsumeSpace.xxs,
              children: [
                for (final tag in entry.tags)
                  NatsumeTag('#$tag', filled: false),
              ],
            ),
          ],
          if (entry.permissions.isNotEmpty) ...[
            const SizedBox(height: NatsumeSpace.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded,
                    size: 12, color: ac.textTertiary),
                const SizedBox(width: NatsumeSpace.xxs),
                Expanded(
                  // 只是「作者声明」，不是沙箱；文案别写成保证
                  child: Text(
                    '声明能力：${entry.permissions.join('、')}',
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textTertiary, height: 1.4),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: NatsumeSpace.xs),
          // 下载量 / 最近更新：GitHub 统计拿不到就整行不显示（不写「0 次」骗人）
          if (stats != null) ...[
            Row(
              children: [
                Icon(Icons.download_rounded, size: 12, color: ac.textTertiary),
                const SizedBox(width: NatsumeSpace.xxs),
                Text(
                  stats.downloadText,
                  style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
                ),
                if (stats.latestReleaseAt != null) ...[
                  const SizedBox(width: NatsumeSpace.xs),
                  Text(
                    '${PluginStats.formatDate(stats.latestReleaseAt)} 更新',
                    style:
                        NatsumeType.microStyle.copyWith(color: ac.textTertiary),
                  ),
                ],
              ],
            ),
            const SizedBox(height: NatsumeSpace.xxs),
          ],
          // 链接 + 操作一起右对齐，窄屏自动换行（不做 Spacer，避免溢出）
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: NatsumeSpace.xxs,
            runSpacing: NatsumeSpace.xxs,
            children: [
              if (entry.repoUrl != null)
                _linkButton('仓库', Icons.code_rounded, entry.repoUrl!),
              if (entry.changelogUrl != null)
                _linkButton('更新日志', Icons.notes_rounded, entry.changelogUrl!),
              NatsumeIconButton(
                icon: Icons.link_rounded,
                tooltip: '复制下载地址',
                size: 18,
                onPressed: () => _copyDownloadUrl(entry),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: NatsumeSpace.xs),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (action == 'installed')
                Padding(
                  padding: const EdgeInsets.only(left: NatsumeSpace.xs),
                  child: Text('已安装 v${installed?.version ?? ''}',
                      style: NatsumeType.microStyle
                          .copyWith(color: ac.textTertiary)),
                )
              else
                NatsumeButton(
                  label: action == 'update' ? '更新' : '安装',
                  dense: true,
                  kind: action == 'update'
                      ? NatsumeButtonKind.secondary
                      : NatsumeButtonKind.primary,
                  onPressed: () => _install(entry),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _linkButton(String label, IconData icon, String url) {
    return NatsumeButton(
      label: label,
      dense: true,
      kind: NatsumeButtonKind.ghost,
      icon: icon,
      onPressed: () => _openLink(url),
    );
  }

  // ── 安装 / 兜底 ──

  /// 复制原始下载地址：全部镜像都失败时的第一条出路（浏览器直下）
  Future<void> _copyDownloadUrl(RegistryPlugin entry) async {
    await Clipboard.setData(ClipboardData(text: entry.downloadUrl));
    _toast('下载地址已复制');
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _toast('链接无效');
      return;
    }
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) _toast('没有找到可用的浏览器');
  }

  /// 打开详情页：统计、已装版本都带上，进去不用重新请求
  Future<void> _openDetail(RegistryPlugin entry) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PluginDetailScreen(
        entry: entry,
        installed: _installed[entry.id],
        installer: widget.installer,
        stats: _stats[entry.id],
        statsLoader: widget.statsLoader,
        onInstallFromFile: _installFromFile,
        disclaimer: _snapshot?.disclaimer,
      ),
    ));
    if (!mounted) return;
    // 详情页里可能装/更新过，回来刷新一次
    await _loadInstalled();
  }

  /// 安装 / 更新（市场卡片入口）：流程与详情页共用 [PluginInstallFlow]，
  /// 保证两个入口问的问题、给的信息一字不差。
  Future<void> _install(RegistryPlugin entry) async {
    if (_busy.contains(entry.id)) return;
    setState(() => _busy.add(entry.id));
    try {
      await _flow.run(
        context,
        entry,
        installed: _installed[entry.id],
        disclaimer: _snapshot?.disclaimer,
      );
      if (!mounted) return;
      // 成功要刷新「已安装」；失败也刷新一次，防止「其实已装过」的版本冲突
      await _loadInstalled();
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
  }

  /// 本地安装：选 zip → 只读清单让用户确认 → 安装（没有 sha256 参照）。
  Future<void> _installFromFile() async {
    if (_localBusy) return;
    setState(() => _localBusy = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      final path = picked?.path;
      if (path == null || !mounted) return;

      final PluginManifest manifest;
      try {
        manifest = await PluginRegistryService.instance.inspectZip(path);
      } on PluginRegistryException catch (e) {
        _toast(e.message);
        return;
      }
      if (!mounted) return;

      final title = manifest.name.isEmpty ? manifest.id : manifest.name;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('安装「$title」？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('版本：${manifest.version}'),
                if (manifest.author != null) Text('作者：${manifest.author}'),
                if (manifest.description != null)
                  Text('说明：${manifest.description}'),
                const SizedBox(height: NatsumeSpace.sm),
                Text(
                  '声明能力：${manifest.capabilities.isEmpty ? '无' : manifest.capabilities.join('、')}',
                ),
                const SizedBox(height: NatsumeSpace.sm),
                Text(
                  '本地安装没有登记表可比对：没有 sha256 参照，'
                  '只能确认包和来源都是你信任的。插件为声明式包，不执行任意代码。',
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(ctx).danger, height: 1.5),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('安装')),
          ],
        ),
      );
      if (ok != true || !mounted) return;

      final result = await PluginRegistryService.instance.installFromZip(path);
      await _loadInstalled();
      if (!mounted) return;
      final version = result.loaded.manifest.version;
      _toast(result.updated
          ? '已更新「$title」到 v$version'
          : '已安装「$title」v$version');
    } on PluginRegistryException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('安装失败：$e');
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }
}
