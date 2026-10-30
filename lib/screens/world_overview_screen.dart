import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
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

  @override
  void initState() {
    super.initState();
    if (widget.autoload) _reload();
  }

  /// 供 MainShell 切 Tab 时调用（与 StatsTabState.refresh 同口径）。
  Future<void> refresh() => _reload();

  Future<void> _reload() async {
    final worlds = await _db.getAllWorlds();
    final plugins = await _db.getAllPlugins();
    if (!mounted) return;
    setState(() {
      _worlds = worlds;
      _plugins = plugins;
    });
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
                                Text(p.name,
                                    style: NatsumeType.h3Style.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: ac.textPrimary)),
                                const SizedBox(width: NatsumeSpace.xs),
                                if (p.author != null)
                                  Text('by ${p.author}',
                                      style: NatsumeType.microStyle.copyWith(
                                          color: ac.textTertiary)),
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
          ],
        ),
      ),
    );
  }

  Future<void> _togglePlugin(PluginInfo p, bool enabled) async {
    await _db.setPluginEnabled(p.id, enabled);
    // 内置插件（双链笔记 / 小鲸助教）要立刻反映到「我的 → 学习工具」入口
    if (p.id == BuiltinPlugins.notesId && mounted) {
      await context.read<AppState>().setNotesPluginEnabled(enabled);
    } else if (p.id == BuiltinPlugins.companionId && mounted) {
      await context.read<AppState>().setCompanionPluginEnabled(enabled);
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

  Future<void> _importPlugin() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null) return;
    final path = result.files.first.path;
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'natsume-world'],
    );
    if (result == null) return;
    final path = result.files.first.path;
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
      await Share.shareXFiles([XFile(path)], subject: 'NatsumeQuizMaster世界导出');
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
