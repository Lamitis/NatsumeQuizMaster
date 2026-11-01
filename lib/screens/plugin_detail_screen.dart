import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/plugin.dart';
import '../services/plugins/plugin_registry.dart';
import '../services/plugins/plugin_stats_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/plugin_discussion.dart';
import '../widgets/plugin_install_flow.dart';

/// 插件详情页（v1.36）。
///
/// 市场列表只放得下一行说明，装之前想知道「这人是谁、多大、最近更新、有没有人用、
/// 出问题去哪问」——这些都在这一页：
/// - **头部**：名字 / 版本 / 分类 / 作者 / 安装按钮 / 版本历史下拉；
/// - **快捷链接**：源码仓库、更新日志、问题反馈、项目主页（全部走浏览器）；
/// - **信息表**：作者 / 版本 / 分类 / License / 大小 / 更新时间 / 下载量 / 仓库；
/// - **讨论区**：Giscus（WebView）；参数没填或平台没有 WebView 时退化成外链按钮。
///
/// 统计（下载量 / 版本历史 / License）全部可失败：拿不到就显示「—」，
/// 不挡安装、不挡浏览。安装流程与列表页共用 [PluginInstallFlow]。
class PluginDetailScreen extends StatefulWidget {
  const PluginDetailScreen({
    super.key,
    required this.entry,
    this.installed,
    this.installer,
    this.stats,
    this.statsLoader,
    this.repoMetaLoader,
    this.onOpenLink,
    this.onInstallFromFile,
    this.webViewAvailable,
    this.discussionConfig = GiscusConfig.current,
    this.disclaimer,
  });

  final RegistryPlugin entry;

  /// 本机已装版本（null = 没装）；装/更新成功后本页会自己刷新
  final PluginInfo? installed;

  /// 缺省走 [PluginRegistryService.instance.install]
  final PluginInstallCall? installer;

  /// 列表页已经拉好的统计，传进来就不用再请求一次
  final PluginStats? stats;

  /// 缺省走 [PluginStatsService.instance.load]
  final PluginStatsBatchLoader? statsLoader;

  /// 缺省走 [PluginStatsService.instance.loadRepoMeta]
  final RepoMetaLoader? repoMetaLoader;

  /// 外链打开方式（测试注入；缺省 launchUrl）
  final Future<void> Function(String url)? onOpenLink;

  /// 失败兜底里的「从本地安装」（列表页传自己的选文件入口）
  final Future<void> Function()? onInstallFromFile;

  /// 强制指定 WebView 可用性（widget 测试传 false）
  final bool? webViewAvailable;

  final GiscusConfig discussionConfig;

  /// 登记表的 disclaimer 原文（一次性来源说明里展示）
  final String? disclaimer;

  @override
  State<PluginDetailScreen> createState() => _PluginDetailScreenState();
}

class _PluginDetailScreenState extends State<PluginDetailScreen> {
  late PluginInfo? _installed;
  PluginStats? _stats;
  PluginRepoMeta? _meta;
  bool _busy = false;
  bool _statsLoading = false;
  String? _statsNote;

  late final PluginInstallFlow _flow = PluginInstallFlow(
    install: widget.installer ?? PluginRegistryService.instance.install,
    onInstallFromFile: widget.onInstallFromFile,
  );

  GitHubRepoRef? get _ref => PluginStatsService.repoOf(widget.entry);

  @override
  void initState() {
    super.initState();
    _installed = widget.installed;
    _stats = widget.stats;
    _loadStats();
  }

  /// 统计是锦上添花：任何失败都只落一行小字，不弹窗、不阻塞。
  Future<void> _loadStats({bool force = false}) async {
    if (_statsLoading) return;
    final needStats = widget.stats == null;
    final ref = _ref;
    if (!needStats && (ref == null || !force)) {
      return;
    }
    setState(() {
      _statsLoading = true;
      if (force) _statsNote = null;
    });
    try {
      if (needStats || force) {
        final loader = widget.statsLoader ?? PluginStatsService.instance.load;
        final snapshot = await loader([widget.entry], forceRefresh: force);
        if (!mounted) return;
        setState(() {
          _stats = snapshot.byPluginId[widget.entry.id] ?? _stats;
          if (snapshot.rateLimited) {
            _statsNote = 'GitHub 限额了，下载量可能不是最新的';
          } else if (snapshot.failure != null) {
            _statsNote = snapshot.failure;
          }
        });
      }
      if (ref == null) return;
      final metaLoader =
          widget.repoMetaLoader ?? PluginStatsService.instance.loadRepoMeta;
      final meta = await metaLoader(ref, forceRefresh: force);
      if (!mounted || meta == null) return;
      setState(() => _meta = meta);
    } catch (_) {
      // 统计失败不影响页面
    } finally {
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  Future<void> _install() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await _flow.run(
        context,
        widget.entry,
        installed: _installed,
        disclaimer: widget.disclaimer,
      );
      if (!mounted || !ok) return;
      await _reloadInstalled();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reloadInstalled() async {
    try {
      final map = await PluginRegistryService.instance.installedMap();
      if (!mounted) return;
      setState(() => _installed = map[widget.entry.id]);
    } catch (_) {}
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      _toast('链接无效');
      return;
    }
    final open = widget.onOpenLink;
    if (open != null) {
      await open(url);
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
        title: const Text('插件详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新下载量与版本信息',
            onPressed: _statsLoading ? null : () => _loadStats(force: true),
          ),
        ],
      ),
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            _header(ac),
            if (_statsNote != null) ...[
              const SizedBox(height: NatsumeSpace.xxs),
              Padding(
                padding: const EdgeInsets.only(left: NatsumeSpace.xxs),
                child: Text(
                  '统计没能更新：$_statsNote',
                  style: NatsumeType.microStyle
                      .copyWith(color: ac.textTertiary, height: 1.4),
                ),
              ),
            ],
            const SizedBox(height: NatsumeSpace.sm),
            _links(ac),
            const SizedBox(height: NatsumeSpace.md),
            _description(ac),
            const SizedBox(height: NatsumeSpace.md),
            _infoTable(ac),
            const SizedBox(height: NatsumeSpace.md),
            PluginDiscussion(
              config: widget.discussionConfig,
              fallbackUrl: _discussionUrl(),
              onOpenLink: _open,
              webViewAvailable: widget.webViewAvailable,
            ),
            const SizedBox(height: NatsumeSpace.lg),
          ],
        ),
      ),
    );
  }

  // ── 头部 ──

  Widget _header(AppThemeColors ac) {
    final entry = widget.entry;
    final stats = _stats;
    final installed = _installed;
    final action = PluginRegistryService.actionFor(entry, installed);
    final menu = _versionMenu(ac);
    return NatsumeSurface(
      padding: const EdgeInsets.all(NatsumeSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _icon(ac),
              const SizedBox(width: NatsumeSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      style: NatsumeType.h1Style.copyWith(
                          fontWeight: FontWeight.w600, color: ac.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: NatsumeSpace.xxs,
                      runSpacing: NatsumeSpace.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('v${entry.version}',
                            style: NatsumeType.microStyle
                                .copyWith(color: ac.textTertiary)),
                        NatsumeTag(entry.categoryLabel, filled: false),
                        if (installed != null)
                          NatsumeTag(
                            action == 'update' ? '可更新' : '已安装',
                            tone: action == 'update'
                                ? NatsumeTagTone.warning
                                : NatsumeTagTone.success,
                          ),
                        if (stats != null)
                          NatsumeTag(
                            stats.downloadText,
                            filled: false,
                            tone: NatsumeTagTone.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: NatsumeSpace.xxs),
                    Text('by ${entry.author}',
                        style: NatsumeType.microStyle
                            .copyWith(color: ac.textTertiary)),
                  ],
                ),
              ),
              if (menu != null) ...[
                const SizedBox(width: NatsumeSpace.xxs),
                menu,
              ],
            ],
          ),
          const SizedBox(height: NatsumeSpace.sm),
          Row(
            children: [
              if (action == 'installed')
                Expanded(
                  child: Text(
                    '已安装 v${installed?.version ?? ''}；'
                    '启停与卸载在「世界总览 → 插件」',
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textTertiary, height: 1.5),
                  ),
                )
              else
                NatsumeButton(
                  label: action == 'update' ? '更新到 v${entry.version}' : '安装插件',
                  icon: Icons.download_rounded,
                  onPressed: _busy ? null : _install,
                ),
              if (_busy) ...[
                const SizedBox(width: NatsumeSpace.xs),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 图标位：插件包没有图标资源，用名字首字做个方块（比通用图标好认）
  Widget _icon(AppThemeColors ac) {
    final name = widget.entry.name.trim();
    final initial = name.isEmpty ? '插' : String.fromCharCode(name.runes.first);
    return Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ac.accentSoft,
        borderRadius: BorderRadius.circular(NatsumeRadius.control),
        border: Border.all(color: ac.border, width: NatsumeLine.width),
      ),
      child: Text(
        initial,
        style: NatsumeType.h1Style.copyWith(
            color: ac.accent, fontWeight: FontWeight.w700),
      ),
    );
  }

  /// 版本历史下拉：点某个版本就去 GitHub 看那一次发布的说明
  Widget? _versionMenu(AppThemeColors ac) {
    final releases = _stats?.releases ?? const <PluginRelease>[];
    final ref = _ref;
    if (releases.isEmpty || ref == null) return null;
    return PopupMenuButton<String>(
      tooltip: '版本历史',
      onSelected: (tag) => _open(ref.releaseUrl(tag)),
      itemBuilder: (context) => [
        for (final r in releases.take(10))
          PopupMenuItem<String>(
            value: r.tag,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.tag,
                    style: NatsumeType.captionStyle.copyWith(
                        color: AppThemeColors.of(context).textPrimary,
                        fontWeight: FontWeight.w600)),
                Text(
                  '${PluginStats.formatDate(r.publishedAt)} · '
                  '${PluginStats.formatCount(r.downloadCount)} 次下载',
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(context).textTertiary),
                ),
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
            Text('版本历史',
                style: NatsumeType.microStyle.copyWith(color: ac.accent)),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: ac.accent),
          ],
        ),
      ),
    );
  }

  // ── 快捷链接 ──

  Widget _links(AppThemeColors ac) {
    final entry = widget.entry;
    final ref = _ref;
    final homepage = _meta?.homepage;
    final links = <(String, IconData, String)>[
      if (entry.repoUrl != null) ('源码仓库', Icons.code_rounded, entry.repoUrl!),
      if (entry.changelogUrl != null)
        ('更新日志', Icons.notes_rounded, entry.changelogUrl!),
      // 反馈入口用仓库的 issues：登记表没有单独的字段，硬编一个比留空好
      if (ref != null) ('问题反馈', Icons.bug_report_outlined, '${ref.webUrl}/issues'),
      if (homepage != null) ('项目主页', Icons.home_outlined, homepage),
    ];
    if (links.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: NatsumeSpace.xxs,
      runSpacing: NatsumeSpace.xxs,
      children: [
        for (final link in links)
          NatsumeButton(
            label: link.$1,
            dense: true,
            kind: NatsumeButtonKind.ghost,
            icon: link.$2,
            onPressed: () => _open(link.$3),
          ),
      ],
    );
  }

  // ── 说明 ──

  Widget _description(AppThemeColors ac) {
    final entry = widget.entry;
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('插件说明',
              style: NatsumeType.captionStyle.copyWith(
                  color: ac.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: NatsumeSpace.xxs),
          Text(
            entry.description.isEmpty ? '作者没写说明。' : entry.description,
            style: NatsumeType.captionStyle
                .copyWith(color: ac.textSecondary, height: 1.6),
          ),
          if (entry.tags.isNotEmpty) ...[
            const SizedBox(height: NatsumeSpace.xs),
            Wrap(
              spacing: NatsumeSpace.xxs,
              runSpacing: NatsumeSpace.xxs,
              children: [
                for (final tag in entry.tags) NatsumeTag('#$tag', filled: false),
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
        ],
      ),
    );
  }

  // ── 信息表 ──

  Widget _infoTable(AppThemeColors ac) {
    final entry = widget.entry;
    final installed = _installed;
    final stats = _stats;
    final ref = _ref;
    final updatedAt = stats?.latestReleaseAt ?? _meta?.pushedAt;
    final rows = <(String, String)>[
      ('作者', entry.author),
      (
        '版本',
        installed == null
            ? '登记 v${entry.version}'
            : '登记 v${entry.version} · 本机 v${installed.version}'
      ),
      ('分类', entry.categoryLabel),
      ('License', _licenseText()),
      ('大小', PluginStats.formatBytes(stats?.assetSizeBytes)),
      ('更新时间', PluginStats.formatDate(updatedAt)),
      ('下载量', stats == null ? '—' : stats.downloadText),
      if (ref != null) ('仓库', ref.slug),
    ];
    return NatsumeSurface(
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('插件信息',
              style: NatsumeType.captionStyle.copyWith(
                  color: ac.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: NatsumeSpace.xxs),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(row.$1,
                        style: NatsumeType.microStyle
                            .copyWith(color: ac.textTertiary)),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textSecondary, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          if (stats != null)
            Padding(
              padding: const EdgeInsets.only(top: NatsumeSpace.xs),
              child: Text(
                '下载量取自 GitHub 发布页的 asset 计数，本地缓存一天',
                style: NatsumeType.microStyle
                    .copyWith(color: ac.textTertiary, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  /// License 三个来源按可信度排：插件清单自己写的 → GitHub 认出来的 → 未标注
  String _licenseText() {
    final fromManifest = _manifestLicense();
    if (fromManifest != null) return fromManifest;
    final fromRepo = _meta?.license;
    if (fromRepo != null && fromRepo.trim().isNotEmpty) return fromRepo.trim();
    return '未标注';
  }

  String? _manifestLicense() {
    final installed = _installed;
    if (installed == null) return null;
    try {
      final decoded = jsonDecode(installed.manifest);
      if (decoded is Map) {
        final value = decoded['license']?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
    } catch (_) {
      // 清单不是合法 JSON 就算了，不值得为此报错
    }
    return null;
  }

  /// 讨论区兜底地址：优先仓库的 `/discussions`
  String? _discussionUrl() {
    final ref = _ref;
    if (ref != null) return '${ref.webUrl}/discussions';
    return widget.entry.repoUrl;
  }
}
