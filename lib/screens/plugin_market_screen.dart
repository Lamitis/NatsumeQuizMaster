import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/plugin.dart';
import '../services/plugins/plugin_loader.dart';
import '../services/plugins/plugin_registry.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

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
  });

  /// 缺省走 [PluginRegistryService.instance.fetch]
  final RegistryFetcher? fetcher;

  /// 缺省走 [PluginRegistryService.instance.install]
  final RegistryInstaller? installer;

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

  /// 正在安装的插件 id（按钮转圈，防重复点）
  final Set<String> _busy = {};

  /// 本地安装进行中（选文件 + 解包），防连点
  bool _localBusy = false;

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

  Future<PluginInstallResult> _doInstall(RegistryPlugin entry) =>
      (widget.installer ?? PluginRegistryService.instance.install)(entry);

  /// 拉表：失败只提示，不清空 [_snapshot]。
  Future<void> _refresh() async {
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
      await _loadInstalled();
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

  /// 已装插件只用来判断「已安装 / 可更新」；读失败不该挡住浏览，
  /// 但要看得出差别，所以把错误并进顶部提示。
  Future<void> _loadInstalled() async {
    try {
      final map = await PluginRegistryService.instance.installedMap();
      if (!mounted) return;
      setState(() => _installed = map);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error ??= '读取已安装列表失败：$e');
    }
  }

  String _actionFor(RegistryPlugin entry) =>
      PluginRegistryService.actionFor(entry, _installed[entry.id]);

  /// 出现过的分类（条目多的排前面，同数量按名字）；只有一个分类时不显示
  List<String> get _categories {
    final counts = <String, int>{};
    for (final e in _snapshot?.plugins ?? const <RegistryPlugin>[]) {
      counts.update(e.categoryLabel, (v) => v + 1, ifAbsent: () => 1);
    }
    final names = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return names;
  }

  List<RegistryPlugin> get _visible {
    final entries = _snapshot?.plugins ?? const <RegistryPlugin>[];
    return entries.where((e) {
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
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            _header(ac),
            const SizedBox(height: NatsumeSpace.sm),
            _searchBar(ac),
            if (_categories.length > 1) ...[
              const SizedBox(height: NatsumeSpace.xs),
              _categoryBar(),
            ],
            const SizedBox(height: NatsumeSpace.xs),
            _statusBar(ac),
            if (_error != null) ...[
              const SizedBox(height: NatsumeSpace.xs),
              _errorBanner(ac),
            ],
            const SizedBox(height: NatsumeSpace.sm),
            ..._content(ac),
            const SizedBox(height: NatsumeSpace.lg),
          ],
        ),
      ),
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
        hintText: '搜索插件名 / 作者 / 标签',
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
    return NatsumeSurface(
      padding: const EdgeInsets.all(NatsumeSpace.sm),
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

  /// 安装前的一次性来源说明（与服务层同一个 key，看一次就够）。返回 true 才继续。
  Future<bool> _ensureDisclaimer(RegistrySnapshot? snapshot) async {
    if (await PluginRegistryService.instance.hasAcceptedDisclaimer()) {
      return true;
    }
    if (!mounted) return false;
    final text = (snapshot?.disclaimer ?? '').isEmpty
        ? '本表只登记插件信息，不审核、不托管插件文件，也不保证插件安全。'
            '插件由各自作者开发和发布，安装与使用风险自负。'
        : snapshot!.disclaimer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('插件来源说明'),
        content: SingleChildScrollView(
          child: Text('$text\n\n'
              '客户端只会做两件机械校验：下载地址必须属于 GitHub 系域名、'
              '下载后重算 sha256 与登记表一致。校验通过不代表代码安全，'
              '装不装由你决定（不会自动安装、不会静默升级）。'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('先不装')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我已经了解')),
        ],
      ),
    );
    if (ok == true) {
      await PluginRegistryService.instance.acceptDisclaimer();
    }
    return ok == true;
  }

  /// 登记表安装 / 更新：来源说明 → 清单确认 → 下载校验 → 提示结果。
  Future<void> _install(RegistryPlugin entry) async {
    final installed = _installed[entry.id];
    final action = _actionFor(entry);
    if (!await _ensureDisclaimer(_snapshot)) return;
    if (!mounted) return;

    // 安装/更新都要用户点确认：登记表证明不了代码安全
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'update'
            ? '更新插件「${entry.name}」？'
            : '安装插件「${entry.name}」？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('作者：${entry.author}'),
              Text('登记版本：${entry.version}'),
              if (installed != null) Text('本机版本：${installed.version}'),
              if (entry.category != null) Text('分类：${entry.category}'),
              const SizedBox(height: NatsumeSpace.xs),
              Text(entry.description),
              if (entry.permissions.isNotEmpty) ...[
                const SizedBox(height: NatsumeSpace.xs),
                Text('作者声明会用到的能力：${entry.permissions.join('、')}',
                    style: NatsumeType.microStyle.copyWith(
                        color: AppThemeColors.of(ctx).textSecondary,
                        height: 1.5)),
              ],
              const SizedBox(height: NatsumeSpace.sm),
              Text('下载地址（仅 GitHub 域名）',
                  style: NatsumeType.microStyle
                      .copyWith(color: AppThemeColors.of(ctx).textTertiary)),
              Text(entry.downloadUrl,
                  style: NatsumeType.microStyle
                      .copyWith(color: AppThemeColors.of(ctx).textSecondary)),
              const SizedBox(height: NatsumeSpace.xs),
              Text('sha256：${entry.sha256}',
                  style: NatsumeType.microStyle
                      .copyWith(color: AppThemeColors.of(ctx).textTertiary)),
              const SizedBox(height: NatsumeSpace.sm),
              Text('安装时会在本机重算 sha256 比对，不一致直接拒绝；'
                  '插件是声明式包，不执行任意第三方代码。',
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(ctx).danger, height: 1.5)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action == 'update' ? '更新' : '安装')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy.add(entry.id));
    try {
      final result = await _doInstall(entry);
      await _loadInstalled();
      if (!mounted) return;
      final version = result.loaded.manifest.version;
      _toast(result.updated
          ? '已更新「${result.entry.name}」到 v$version'
          : '已安装「${result.entry.name}」v$version');
    } on PluginRegistryException catch (e) {
      await _showInstallFailure(e);
    } catch (e) {
      _toast('安装失败：$e');
    } finally {
      if (mounted) setState(() => _busy.remove(entry.id));
    }
  }

  /// 安装失败的兜底出口：复制原始地址 / 改用本地 zip。
  Future<void> _showInstallFailure(PluginRegistryException e) async {
    if (!mounted) return;
    final url = e.downloadUrl;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装没有完成'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.message),
              if (url != null) ...[
                const SizedBox(height: NatsumeSpace.sm),
                Text(
                  '所有下载源都没成功。可以复制原始下载地址，'
                  '用浏览器下载后点右上角「从本地文件安装」：',
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(ctx).textSecondary, height: 1.5),
                ),
                const SizedBox(height: NatsumeSpace.xxs),
                SelectableText(url,
                    style: NatsumeType.microStyle.copyWith(
                        color: AppThemeColors.of(ctx).textTertiary)),
              ],
            ],
          ),
        ),
        actions: [
          if (url != null)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                _toast('下载地址已复制');
              },
              child: const Text('复制下载地址'),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _installFromFile();
            },
            child: const Text('从本地安装'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
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
