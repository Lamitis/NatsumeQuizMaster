import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/theme_service.dart';
import '../services/update_service.dart';
import '../utils/app_constants.dart';
import '../utils/design_tokens.dart';
import '../utils/format_utils.dart';
import '../utils/responsive.dart';
import '../widgets/guide/guide_anchor.dart';
import '../widgets/guide/guide_steps.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/kit/natsume_logo.dart';
import 'companion_screen.dart';
import 'developer_options_screen.dart';
import 'knowledge_base_screen.dart';
import 'notes_screen.dart';
import 'question_generator_screen.dart';
import 'schedule_screen.dart';
import 'settings_hub_screen.dart';
import 'world_overview_screen.dart';

/// 我的页（Natsume Des 2.0 · 精密暗色）
///
/// 问候卡（平坦面板 + 左侧强调条）+ 入口列表 + 产品定位卡。
/// 与首页语言一致：层级靠发丝描边与明度差，不用大色块与阴影。
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  // v1.0.2 设计审查修复：问候语逻辑收敛到 format_utils.greetingNow
  String get _greeting => greetingNow();

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final nickname = context.watch<AppState>().settings.nickname;
    // v1.0.3 宽屏重设计：入口卡片提取为列表，窄屏纵列 / 宽屏三列并排
    final entries = [
      GuideAnchor(
        // 引导锚点：首启引导末步高亮「设置」
        id: GuideAnchorIds.profileSettings,
        child: _EntryTile(
          icon: Icons.settings_outlined,
          title: '设置',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsHubScreen()),
          ),
        ),
      ),
      _EntryTile(
        icon: Icons.developer_mode,
        title: '开发者选项',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const DeveloperOptionsScreen()),
        ),
      ),
      _EntryTile(
        icon: Icons.info_outline,
        title: '关于',
        // v1.0.2 修复：版本号统一（常量 kAppVersion）
        subtitle: kAppVersion,
        onTap: () => _showAbout(context),
      ),
    ];

    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(title: const Text('我的')),
      // 平板适配：内容限宽居中（手机无影响）；宽屏限宽自动提升至 1080
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            // ── 问候卡：平坦面板 + 左侧强调条 + 单色 logo 方块 ──
            NatsumeSurface(
              accentEdge: true,
              padding: const EdgeInsets.all(NatsumeSpace.md),
              child: Row(
                children: [
                  // 品牌位：与首页/启动页同一组件，三处形状与裁切一致
                  const NatsumeLogoBadge(box: 42),
                  const SizedBox(width: NatsumeSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_greeting,
                            style: NatsumeType.h1Style
                                .copyWith(color: ac.textPrimary)),
                        const SizedBox(height: NatsumeSpace.xxs),
                        Text(
                          // v1.0.2 对齐里程碑：昵称（设置后首页显示专属问候）
                          nickname.isEmpty ? 'NatsumeQuizMaster' : nickname,
                          style: NatsumeType.captionStyle
                              .copyWith(color: ac.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: NatsumeSpace.lg),
            const NatsumeSectionHeader(
              title: '个人空间',
              subtitle: '设置、数据与使用帮助',
            ),
            const SizedBox(height: NatsumeSpace.sm),
            // ── 入口列表：宽屏三列并排，窄屏纵列 ──
            if (isWideLayout(context))
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: entries[0]),
                  const SizedBox(width: NatsumeSpace.xs),
                  Expanded(child: entries[1]),
                  const SizedBox(width: NatsumeSpace.xs),
                  Expanded(child: entries[2]),
                ],
              )
            else ...[
              entries[0],
              const SizedBox(height: NatsumeSpace.xs),
              entries[1],
              const SizedBox(height: NatsumeSpace.xs),
              entries[2],
            ],
            const SizedBox(height: NatsumeSpace.xs),
            // 第 4 项整行：不挤进上面那排（宽屏三列 / 窄屏纵列都保持可读）
            // 重看引导 = 请求根节点的引导控制器再播一遍（遮罩盖在 Navigator 之上）
            _EntryTile(
              icon: Icons.school_outlined,
              title: '使用引导',
              onTap: () => GuideScope.maybeOf(context)?.start(),
            ),
            const SizedBox(height: NatsumeSpace.xs),
            // 第 5 项：检查更新（清华镜像优先，失败回落 GitHub Releases）
            _EntryTile(
              icon: Icons.system_update_alt,
              title: '检查更新',
              subtitle: '当前版本 $kAppVersion · 镜像优先，失败回落实时仓库',
              onTap: () => _showUpdateDialog(context),
            ),
            const SizedBox(height: NatsumeSpace.lg),
            // ── 学习工具（v13：知识库 / 自动出题 / 世界总览）──
            const NatsumeSectionHeader(
              title: '学习工具',
              subtitle: '知识库约束、自动出题与世界插件',
            ),
            const SizedBox(height: NatsumeSpace.sm),
            _EntryTile(
              icon: Icons.menu_book_outlined,
              title: '知识库',
              subtitle: '导入资料，约束 AI 解释与出题（防幻觉）',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const KnowledgeBaseScreen()),
              ),
            ),
            const SizedBox(height: NatsumeSpace.xs),
            _EntryTile(
              icon: Icons.auto_awesome,
              title: '自动出题',
              subtitle: '基于知识库由 AI 生成题目',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const QuestionGeneratorScreen()),
              ),
            ),
            const SizedBox(height: NatsumeSpace.xs),
            _EntryTile(
              icon: Icons.public_outlined,
              title: '世界总览',
              subtitle: '世界与插件的打包、导入与分享',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WorldOverviewScreen()),
              ),
            ),
            // v1.31 笔记插件入口：插件停用时整条隐藏（用户在世界总览里关掉即收起）
            if (context.watch<AppState>().notesPluginEnabled) ...[
              const SizedBox(height: NatsumeSpace.xs),
              _EntryTile(
                icon: Icons.sticky_note_2_outlined,
                title: '双链笔记',
                // 同步边界写在入口上：插件数据不入同步清单，用户点进去前就该知道
                subtitle: '刷题随手记 · [[双链]] 与 Graph · 本机保存（无法同步）',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NotesScreen()),
                ),
              ),
            ],
            // v1.32 小鲸助教：同样是内置插件，停用后整条收起
            if (context.watch<AppState>().companionPluginEnabled) ...[
              const SizedBox(height: NatsumeSpace.xs),
              _EntryTile(
                icon: Icons.pets_outlined,
                title: '小鲸助教',
                subtitle: '鲸鱼娘陪伴 · 按连胜与正确率打气 · 本机保存（无法同步）',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CompanionScreen()),
                ),
              ),
            ],
            // v1.34 日程待办插件：停用后整条收起（与笔记/陪伴同一规则）
            if (context.watch<AppState>().schedulePluginEnabled) ...[
              const SizedBox(height: NatsumeSpace.xs),
              _EntryTile(
                icon: Icons.event_note_outlined,
                title: '日程待办',
                subtitle: '复习计划拆成待办 · 按日排期与勾选 · 本机保存（无法同步）',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ScheduleScreen()),
                ),
              ),
            ],
            const SizedBox(height: NatsumeSpace.lg),
            // ── 产品定位卡（消除下半屏空白） ──
            NatsumeSurface(
              tone: NatsumeTone.alt,
              padding: const EdgeInsets.all(NatsumeSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NatsumeQuizMaster · 医学备考刷题平台',
                      style: NatsumeType.h3Style.copyWith(
                          fontWeight: FontWeight.w600, color: ac.textPrimary)),
                  const SizedBox(height: NatsumeSpace.xs),
                  Text(
                    '开源免费，无广告无会员\n题库与记录本地存储，数据自有\nAI 讲解使用你的 API Key，请求发往所配置的服务商\n许可：AGPL-3.0（可自由使用 / 修改 / 分发）',
                    style: NatsumeType.captionStyle
                        .copyWith(height: 1.75, color: ac.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: NatsumeSpace.lg),
            Center(
              child: Text(
                // 页脚：版权与版本号，保持克制，不放个人化文案
                '© 2026 夏目安安（Natsume An-An）· $kAppVersion',
                style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 检查更新：镜像 / GitHub 都失败也给可读原因，不弹红屏
  void _showUpdateDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _UpdateDialog(),
    );
  }

  void _showAbout(BuildContext context) {
    final ac = AppThemeColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('NatsumeQuizMaster'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              // v1.0.2 定位：医学生备考（未来拓展通用场景）
              '医学备考刷题工具\n支持本地题库、知识库约束 AI 解析、FSRS 间隔复习、数据统计。',
            ),
            const SizedBox(height: NatsumeSpace.sm),
            Text('版本：$kAppVersion',
                style:
                    NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showOpenSource(context);
            },
            child: const Text('开源致谢'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  void _showOpenSource(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开源致谢'),
        content: const SingleChildScrollView(
          child: Text(
            '本项目基于开源生态二次开发，感谢以下项目：\n\n'
            '· daimao-quiz「猫卷」（AGPL-3.0，Copyright (C) 2026 笨蛋鱼坏蛋猫）—— 基础架构\n'
            '· NoteLLM（MIT）—— 知识库切块思路\n'
            '· Syncthing（MPL-2.0）—— 跨端同步思路\n'
            '· Logseq（AGPL-3.0）—— 双链笔记格式与 Graph 交互（仅取形，未引入源码）\n'
            '· dsh-bili-scroll / fishtalk（MIT）—— 插件与 Agent 思路\n\n'
            '完整许可清单见 THIRD_PARTY_NOTICES.md。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

}

/// 入口行：单色描边小图标 + 标题（副标题另起一行）+ 细箭头。
///
/// 2026-10-08 修复：此前副标题与标题同处一个 Row 且副标题不参与伸缩，
/// 长副标题会把标题的 Expanded 挤到接近 0 宽，中文于是逐字换行变成竖排
/// （真机截图：我的页「重看使用引导」）。现在标题与副标题纵向排列在
/// Expanded 内，任何长度的副标题都不会再挤压标题。
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return NatsumeSurface(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.sm),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: ac.surfaceAlt,
              borderRadius: NatsumeRadius.smallBorder,
              border: Border.all(color: ac.border, width: NatsumeLine.width),
            ),
            child: Icon(icon, size: 16, color: ac.accent),
          ),
          const SizedBox(width: NatsumeSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.h3Style.copyWith(
                        fontWeight: FontWeight.w600, color: ac.textPrimary)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textTertiary)),
                ],
              ],
            ),
          ),
          const SizedBox(width: NatsumeSpace.xxs),
          Icon(Icons.chevron_right_rounded, size: 16, color: ac.textTertiary),
        ],
      ),
    );
  }
}

/// 「检查更新」对话框（v1.34）。
///
/// 打开即查一次；三种结果各给一句话 + 下一步动作：
///   有新版本 → 显示当前/最新版本与说明，主按钮「前往下载」（外部浏览器）
///   已最新   → 显示当前版本，无主按钮
///   失败     → 显示两路失败原因，「重试」原地再查（不用关掉重进）
///
/// 下载一律走外部浏览器：应用商店/安装包渠道随平台不同，App 内自更新
/// 在 Android 上还会触发未知来源安装权限，属于另一个量级的功能。
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _loading = true;
  bool _opening = false;
  UpdateCheckResult? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _loading = true);
    final result = await UpdateService.check();
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  Future<void> _openDownload(String url) async {
    setState(() => _opening = true);
    final ok = await UpdateService.openDownload(url);
    if (!mounted) return;
    setState(() => _opening = false);
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('无法打开链接，请手动访问：$url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final result = _result;
    final hasUpdate = result?.hasUpdate ?? false;
    final downloadUrl = result?.downloadUrl;

    return AlertDialog(
      title: const Text('检查更新'),
      content: SizedBox(
        width: dialogContentWidth(context),
        child: _loading
            ? Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: NatsumeSpace.sm),
                  Expanded(
                    child: Text('正在连接更新服务器…',
                        style: NatsumeType.captionStyle
                            .copyWith(color: ac.textSecondary)),
                  ),
                ],
              )
            : SingleChildScrollView(child: _buildBody(context, result)),
      ),
      actions: [
        if (!_loading && result != null && result.failed)
          TextButton(onPressed: _run, child: const Text('重试')),
        if (hasUpdate && downloadUrl != null)
          FilledButton(
            onPressed: _opening ? null : () => _openDownload(downloadUrl),
            child: Text(_opening ? '正在打开…' : '前往下载'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(hasUpdate ? '稍后' : '好的'),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, UpdateCheckResult? result) {
    final ac = AppThemeColors.of(context);
    if (result == null) return const SizedBox.shrink();

    if (result.status == UpdateStatus.failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('暂时查不到新版本',
              style:
                  NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
          const SizedBox(height: NatsumeSpace.xs),
          Text(
            result.error ?? '未知原因',
            style: NatsumeType.captionStyle
                .copyWith(color: ac.textSecondary, height: 1.6),
          ),
          const SizedBox(height: NatsumeSpace.sm),
          Text(
            '提示：网络受限时可稍后重试，或手动前往 GitHub Releases 查看。',
            style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
          ),
        ],
      );
    }

    if (!result.hasUpdate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('已是最新版本',
              style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
          const SizedBox(height: NatsumeSpace.xs),
          Text('当前版本 ${result.currentVersion}',
              style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
          if (result.source != null) ...[
            const SizedBox(height: 2),
            Text('检查来源：${result.source}',
                style:
                    NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('发现新版本 ${result.latestVersion ?? ''}',
            style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
        const SizedBox(height: NatsumeSpace.xs),
        Text('当前版本 ${result.currentVersion}',
            style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
        if (result.source != null) ...[
          const SizedBox(height: 2),
          Text('检查来源：${result.source}',
              style: NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
        ],
        if ((result.notes ?? '').isNotEmpty) ...[
          const SizedBox(height: NatsumeSpace.sm),
          Text('更新说明',
              style: NatsumeType.captionStyle.copyWith(
                  fontWeight: FontWeight.w600, color: ac.textPrimary)),
          const SizedBox(height: NatsumeSpace.xxs),
          Text(result.notes!,
              style: NatsumeType.captionStyle
                  .copyWith(color: ac.textSecondary, height: 1.6)),
        ],
      ],
    );
  }
}

