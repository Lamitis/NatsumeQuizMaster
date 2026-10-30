import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/plugin.dart';
import '../models/world.dart';
import '../services/app_state.dart';
import '../services/database_service.dart';
import '../services/export_storage.dart';
import '../services/integrity_service.dart';
import '../services/knowledge_base/kb_service.dart';
import '../services/plugins/builtin_plugins.dart';
import '../services/plugins/plugin_loader.dart';
import '../services/plugins/plugin_registry.dart';
import '../services/plugins/world_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

/// 世界总览（v13 · world-overview）。
///
/// 「世界」= 知识库 + 题库 + 插件 的打包单元，可整体导出/导入/分享；
/// 插件是声明式包（清单 + 提示词 + 可选资产），安装前展示摘要、可启用/停用。
class WorldOverviewScreen extends StatefulWidget {
  /// [autoload]：为 true（作为独立路由 push 进来时）在首帧即加载数据；
  /// 为 false（作为主壳第 5 个 IndexedStack Tab 时）由 MainShell 切到该 Tab
  /// 时调用 [WorldOverviewScreenState.refresh] 再加载——避免 IndexedStack 预构建
  /// 所有子页时，未访问页在 initState 里发起查询、测试收尾关闭库后抛出
  /// 「database closed」。
  const WorldOverviewScreen({super.key, this.autoload = true});

  final bool autoload;

  @override
  State<WorldOverviewScreen> createState() => WorldOverviewScreenState();
}

class WorldOverviewScreenState extends State<WorldOverviewScreen> {
  final DatabaseService _db = DatabaseService.instance;

  List<WorldInfo> _worlds = [];
  List<PluginInfo> _plugins = [];

  /// 第三方插件表（v1.35 · Natsume-Registry）。
  ///
  /// [registry] 为 null 表示**还没成功拉到过**；拉取失败时保留上一次的快照，
  /// 只在 [_registryError] 里写一句「这次没拉到」，绝不把已有列表清空。
  RegistrySnapshot? _registry;
  bool _registryLoading = false;
  String? _registryError;

  /// 正在安装的插件 id（按钮转圈，防重复点）
  final Set<String> _installing = {};

  /// 已安装插件（id → 行），用于「已安装 / 可更新」
  Map<String, PluginInfo> _installed = {};

  @override
  void initState() {
    super.initState();
    if (widget.autoload) {
      _reload();
      _loadRegistry();
    }
  }

  /// 供 MainShell 切 Tab 时调用（与 StatsTabState.refresh 同口径）。
  Future<void> refresh() {
    _loadRegistry();
    return _reload();
  }

  Future<void> _reload() async {
    final worlds = await _db.getAllWorlds();
    final plugins = await _db.getAllPlugins();
    if (!mounted) return;
    setState(() {
      _worlds = worlds;
      _plugins = plugins;
      _installed = {for (final p in plugins) p.id: p};
    });
  }

  /// 拉插件登记表：失败只提示，不清空 [_registry]。
  Future<void> _loadRegistry() async {
    if (_registryLoading) return;
    setState(() {
      _registryLoading = true;
      _registryError = null;
    });
    try {
      final snapshot = await PluginRegistryService.instance.fetch();
      if (!mounted) return;
      setState(() {
        _registry = snapshot;
        _registryLoading = false;
      });
    } on PluginRegistryException catch (e) {
      if (!mounted) return;
      setState(() {
        _registryLoading = false;
        _registryError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _registryLoading = false;
        _registryError = '插件表读取失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('世界总览')),
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            NatsumeSectionHeader(
              title: '世界',
              subtitle: '知识库 + 题库 + 插件 打包成单一文件，可分享给同学',
              trailing: NatsumeButton(
                label: '导出',
                dense: true,
                icon: Icons.ios_share_outlined,
                onPressed: _exportWorld,
              ),
            ),
            const SizedBox(height: NatsumeSpace.sm),
            if (_worlds.isEmpty)
              NatsumeEmptyState(
                icon: Icons.public_outlined,
                title: '还没有世界',
                description: '点「导入世界」安装一个 .natsume-world 文件',
              )
            else
              for (final w in _worlds) ...[
                NatsumeSurface(
                  padding: const EdgeInsets.all(NatsumeSpace.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(w.name,
                                style: NatsumeType.h3Style.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: ac.textPrimary)),
                            Text('v${w.version}',
                                style: NatsumeType.microStyle
                                    .copyWith(color: ac.textTertiary)),
                          ],
                        ),
                      ),
                      NatsumeIconButton(
                        icon: Icons.delete_outline,
                        tooltip: '删除',
                        onPressed: () => _deleteWorld(w),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NatsumeSpace.xs),
              ],
            const SizedBox(height: NatsumeSpace.sm),
            Row(
              children: [
                Expanded(
                  child: NatsumeButton(
                    label: '导入世界',
                    kind: NatsumeButtonKind.secondary,
                    icon: Icons.download_outlined,
                    onPressed: _importWorld,
                  ),
                ),
                const SizedBox(width: NatsumeSpace.sm),
                Expanded(
                  child: NatsumeButton(
                    label: '导入插件',
                    kind: NatsumeButtonKind.ghost,
                    icon: Icons.extension_outlined,
                    onPressed: _importPlugin,
                  ),
                ),
              ],
            ),
            const SizedBox(height: NatsumeSpace.lg),
            NatsumeSectionHeader(title: '插件', subtitle: '第三方开发者制作的声明式扩展'),
            const SizedBox(height: NatsumeSpace.sm),
            if (_plugins.isEmpty)
              NatsumeEmptyState(
                icon: Icons.extension_outlined,
                title: '还没有插件',
                description: '插件可注入提示词、内置知识库与示例题库',
              )
            else
              for (final p in _plugins) ...[
                NatsumeSurface(
                  padding: const EdgeInsets.all(NatsumeSpace.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                // 插件名/作者可能很长：省略号收口，别把开关挤出去
                                Flexible(
                                  child: Text(p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: NatsumeType.h3Style.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: ac.textPrimary)),
                                ),
                                const SizedBox(width: NatsumeSpace.xs),
                                if (p.author != null)
                                  Flexible(
                                    child: Text('by ${p.author}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: NatsumeType.microStyle.copyWith(
                                            color: ac.textTertiary)),
                                  ),
                                // v1.31：插件数据不进同步导出清单，必须显式说明
                                if (!BuiltinPlugins.isSyncable(p)) ...[
                                  const SizedBox(width: NatsumeSpace.xxs),
                                  const NatsumeTag('无法同步',
                                      tone: NatsumeTagTone.warning),
                                ],
                              ],
                            ),
                            if (p.description != null) ...[
                              const SizedBox(height: 2),
                              Text(p.description!,
                                  style: NatsumeType.captionStyle
                                      .copyWith(color: ac.textSecondary)),
                            ],
                            // 声明式包也要交代许可与取形来源（AGPL 合规）
                            if (BuiltinPlugins.byId(p.id) case final b?) ...[
                              const SizedBox(height: 2),
                              Text(
                                'v${p.version} · ${b.license}'
                                '${b.upstream == null ? '' : ' · 取形 ${b.upstream}'}',
                                style: NatsumeType.microStyle
                                    .copyWith(color: ac.textTertiary),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Switch(
                        value: p.enabled,
                        onChanged: (v) => _togglePlugin(p, v),
                      ),
                      NatsumeIconButton(
                        icon: Icons.delete_outline,
                        tooltip: '删除',
                        onPressed: () => _deletePlugin(p),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NatsumeSpace.xs),
              ],
            const SizedBox(height: NatsumeSpace.lg),
            _registrySection(ac),
          ],
        ),
      ),
    );
  }

  /// 插件生态：登记表条目 + 免责声明 + 安装/更新入口。
  Widget _registrySection(AppThemeColors ac) {
    final snapshot = _registry;
    final entries = snapshot?.plugins ?? const <RegistryPlugin>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NatsumeSectionHeader(
          title: '插件生态',
          subtitle: 'Natsume-Registry：只登记信息，不审核、不托管插件文件',
          trailing: _registryLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : NatsumeButton(
                  label: '刷新',
                  dense: true,
                  kind: NatsumeButtonKind.ghost,
                  icon: Icons.refresh_rounded,
                  onPressed: _loadRegistry,
                ),
        ),
        const SizedBox(height: NatsumeSpace.sm),
        // disclaimer 必须能看见（用户要求：列表旁边显示，或安装前弹一次）
        if (snapshot != null && snapshot.disclaimer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
            child: Text(
              snapshot.disclaimer,
              style: NatsumeType.microStyle
                  .copyWith(color: ac.textTertiary, height: 1.5),
            ),
          ),
        if (_registryError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
            child: Row(
              children: [
                const NatsumeTag('本次没拉到', tone: NatsumeTagTone.warning),
                const SizedBox(width: NatsumeSpace.xs),
                Expanded(
                  child: Text(
                    // 拉表失败只提示，列表保持上一次的内容
                    '$_registryError${entries.isEmpty ? '' : '（下面是上次的结果）'}',
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textSecondary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        if (snapshot == null && _registryLoading)
          NatsumeEmptyState(
            icon: Icons.cloud_download_outlined,
            title: '正在读取插件表',
            description: '首次读取需要联网；失败时不会影响已安装插件',
          )
        else if (entries.isEmpty)
          NatsumeEmptyState(
            icon: Icons.storefront_outlined,
            title: '登记表里还没有插件',
            description: '表是空的（count = 0），不是加载失败；'
                '作者提交 PR 后会自动进表',
          )
        else
          for (final entry in entries) ...[
            _registryCard(ac, entry),
            const SizedBox(height: NatsumeSpace.xs),
          ],
        if (snapshot != null && snapshot.generatedAt.isNotEmpty)
          Text(
            '表生成于 ${snapshot.generatedAt}'
            '${snapshot.droppedCount > 0 ? ' · 丢弃 ${snapshot.droppedCount} 条不合规登记' : ''}',
            style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
          ),
      ],
    );
  }

  Widget _registryCard(AppThemeColors ac, RegistryPlugin entry) {
    final installed = _installed[entry.id];
    final action = PluginRegistryService.actionFor(entry, installed);
    final busy = _installing.contains(entry.id);
    return NatsumeSurface(
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NatsumeType.h3Style.copyWith(
                              fontWeight: FontWeight.w600,
                              color: ac.textPrimary)),
                    ),
                    const SizedBox(width: NatsumeSpace.xs),
                    Text('v${entry.version}',
                        style: NatsumeType.microStyle
                            .copyWith(color: ac.textTertiary)),
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
                Text('by ${entry.author}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textTertiary)),
                const SizedBox(height: 2),
                Text(entry.description,
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: NatsumeSpace.xs),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(NatsumeSpace.xs),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (action == 'installed')
            Padding(
              padding: const EdgeInsets.only(top: NatsumeSpace.xxs),
              child: Text('已安装',
                  style:
                      NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
            )
          else
            NatsumeButton(
              label: action == 'update' ? '更新' : '安装',
              dense: true,
              kind: action == 'update'
                  ? NatsumeButtonKind.secondary
                  : NatsumeButtonKind.primary,
              onPressed: () => _installRegistryPlugin(entry),
            ),
        ],
      ),
    );
  }

  Future<void> _togglePlugin(PluginInfo p, bool enabled) async {
    await _db.setPluginEnabled(p.id, enabled);
    // 内置插件（双链笔记 / 小鲸助教 / 日程待办）要立刻反映到「我的 → 学习工具」入口
    if (p.id == BuiltinPlugins.notesId && mounted) {
      await context.read<AppState>().setNotesPluginEnabled(enabled);
    } else if (p.id == BuiltinPlugins.companionId && mounted) {
      await context.read<AppState>().setCompanionPluginEnabled(enabled);
    } else if (p.id == BuiltinPlugins.scheduleId && mounted) {
      await context.read<AppState>().setSchedulePluginEnabled(enabled);
    }
    _reload();
  }

  Future<void> _deletePlugin(PluginInfo p) async {
    await _db.deletePlugin(p.id);
    _reload();
  }

  Future<void> _deleteWorld(WorldInfo w) async {
    await _db.deleteWorld(w.id);
    _reload();
  }

  // ── 插件生态（Natsume-Registry） ──

  /// 安装前的一次性来源说明。返回 true 才继续。
  Future<bool> _ensureDisclaimer(RegistrySnapshot snapshot) async {
    if (await PluginRegistryService.instance.hasAcceptedDisclaimer()) {
      return true;
    }
    if (!mounted) return false;
    final text = snapshot.disclaimer.isEmpty
        ? '本表只登记插件信息，不审核、不托管插件文件，也不保证插件安全。'
            '插件由各自作者开发和发布，安装与使用风险自负。'
        : snapshot.disclaimer;
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

  Future<void> _installRegistryPlugin(RegistryPlugin entry) async {
    final snapshot = _registry;
    if (snapshot == null) return;
    final installed = _installed[entry.id];
    final action = PluginRegistryService.actionFor(entry, installed);

    if (!await _ensureDisclaimer(snapshot)) return;
    if (!mounted) return;

    // 安装/更新都要用户点确认：登记表证明不了代码安全
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'update' ? '更新插件「${entry.name}」？' : '安装插件「${entry.name}」？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('作者：${entry.author}'),
              Text('登记版本：${entry.version}'),
              if (installed != null) Text('本机版本：${installed.version}'),
              const SizedBox(height: NatsumeSpace.xs),
              Text(entry.description),
              const SizedBox(height: NatsumeSpace.sm),
              Text('下载地址（仅 GitHub 域名）',
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(ctx).textTertiary)),
              Text(entry.downloadUrl,
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(ctx).textSecondary)),
              const SizedBox(height: NatsumeSpace.xs),
              Text('sha256：${entry.sha256}',
                  style: NatsumeType.microStyle.copyWith(
                      color: AppThemeColors.of(ctx).textTertiary)),
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

    setState(() => _installing.add(entry.id));
    try {
      final result = await PluginRegistryService.instance.install(entry);
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.updated
            ? '已更新「${result.entry.name}」到 v${result.loaded.manifest.version}'
            : '已安装「${result.entry.name}」v${result.loaded.manifest.version}'),
      ));
    } on PluginRegistryException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('安装失败：$e')));
    } finally {
      if (mounted) setState(() => _installing.remove(entry.id));
    }
  }

  Future<void> _importPlugin() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked?.path;
    if (path == null) return;
    final dir = await ExportStorage.resolve();
    final installDir =
        '${dir.path}${Platform.pathSeparator}plugins';
    final loaded = await PluginLoader.loadFromZip(path, installDir);
    if (!mounted) return;
    // 安装前展示清单摘要（安全红线：能力声明透明可见）
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('安装插件「${loaded.manifest.name}」？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本：${loaded.manifest.version}'),
            if (loaded.manifest.author != null)
              Text('作者：${loaded.manifest.author}'),
            if (loaded.manifest.description != null)
              Text('说明：${loaded.manifest.description}'),
            const SizedBox(height: NatsumeSpace.sm),
            Text('声明能力：${loaded.manifest.capabilities.isEmpty ? '无' : loaded.manifest.capabilities.join('、')}'),
            const SizedBox(height: NatsumeSpace.xs),
            Text('插件为声明式包，不执行任意代码。',
                style: NatsumeType.microStyle.copyWith(
                    color: AppThemeColors.of(ctx).danger)),
          ],
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
    if (ok != true) return;
    await _db.upsertPlugin(PluginInfo(
      id: loaded.manifest.id,
      name: loaded.manifest.name,
      version: loaded.manifest.version,
      author: loaded.manifest.author,
      description: loaded.manifest.description,
      manifest: jsonEncode(loaded.manifest.toJson()),
      installedAt: DateTime.now().toIso8601String(),
    ));
    _reload();
  }

  Future<void> _importWorld() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip', 'natsume-world'],
    );
    final path = picked?.path;
    if (path == null) return;
    try {
      final r = await WorldService.importWorld(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '已导入世界「${r.world.name}」：知识库 ${r.kbCount}、题库 ${r.bankCount}、插件 ${r.pluginCount}')));
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> _exportWorld() async {
    // 防伪：检测到二次打包时静默限制世界导出（高级功能）
    if (IntegrityService.advancedFeaturesLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检测到应用被二次打包，世界导出已受限')));
      return;
    }
    final name = await _promptWorldName();
    if (name == null) return;
    final kbs = await KbService.instance.listKnowledgeBases();
    final banks = await _db.getAllBanks();
    final plugins = await _db.getAllPlugins();
    final dir = await ExportStorage.resolve();
    final dest =
        '${dir.path}${Platform.pathSeparator}${name}.natsume-world.zip';
    final path = await WorldService.exportWorld(
      worldId: const Uuid().v4(),
      worldName: name,
      kbIds: kbs.map((k) => k.id!).whereType<int>().toList(),
      bankIds: banks.map((b) => b.id!).whereType<int>().toList(),
      pluginIds: plugins.map((p) => p.id).toList(),
      destPath: dest,
    );
    if (path != null) {
      // v1.34：导出后直接「另存为」，由用户挑落盘位置
      if (!mounted) return;
      final result =
          await ExportStorage.saveFileAs(path, dialogTitle: '保存世界导出文件');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.saved
            ? '已导出世界到 ${result.path}'
            : '已取消保存。文件仍可在此找到：${ExportStorage.folderOf(path)}'),
        duration: const Duration(seconds: 5),
      ));
    }
  }

  Future<String?> _promptWorldName() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出世界'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '世界名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    controller.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }
}
