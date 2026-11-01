import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/plugin.dart';
import '../services/plugins/plugin_registry.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';

/// 安装 / 更新函数（市场列表与详情页共用；测试注入用）
typedef PluginInstallCall = Future<PluginInstallResult> Function(
    RegistryPlugin entry);

/// 登记表插件的「安装 / 更新」全流程（v1.36 从市场页抽出来，详情页复用同一套）。
///
/// 抽出来的理由不是复用几行 UI，而是**安全流程不能有两条**：
/// 市场卡片和详情页是两个「安装」入口，只要有一处漏了来源说明或确认弹窗，
/// 用户就可能「点一下就连网写盘」。这里保证两条入口问的问题、给的信息一字不差。
///
/// 三步：
/// 1. 一次性来源说明（[PluginRegistryService.hasAcceptedDisclaimer]，看过就不再打扰）；
/// 2. 清单确认（作者 / 版本 / 下载地址 / sha256 / 声明能力）；
/// 3. 安装 + 失败兜底（复制原始地址 / 改用本地 zip）。
class PluginInstallFlow {
  const PluginInstallFlow({
    required this.install,
    this.onInstallFromFile,
  });

  final PluginInstallCall install;

  /// 失败兜底里的「从本地安装」（详情页没有选文件入口时传 null）
  final Future<void> Function()? onInstallFromFile;

  /// 走完整流程；返回 true 表示装/更新成功（提示已由本流程给出）。
  Future<bool> run(
    BuildContext context,
    RegistryPlugin entry, {
    PluginInfo? installed,
    String? disclaimer,
  }) async {
    final action = PluginRegistryService.actionFor(entry, installed);
    if (!await _ensureDisclaimer(context, disclaimer)) return false;
    if (!context.mounted) return false;

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
    if (ok != true || !context.mounted) return false;

    try {
      final result = await install(entry);
      if (!context.mounted) return true;
      final version = result.loaded.manifest.version;
      _toast(
        context,
        result.updated
            ? '已更新「${result.entry.name}」到 v$version'
            : '已安装「${result.entry.name}」v$version',
      );
      return true;
    } on PluginRegistryException catch (e) {
      await _showFailure(context, e);
      return false;
    } catch (e) {
      _toast(context, '安装失败：$e');
      return false;
    }
  }

  /// 安装前的一次性来源说明（与服务层同一个 key，看一次就够）。返回 true 才继续。
  Future<bool> _ensureDisclaimer(
      BuildContext context, String? disclaimer) async {
    if (await PluginRegistryService.instance.hasAcceptedDisclaimer()) {
      return true;
    }
    if (!context.mounted) return false;
    final text = (disclaimer ?? '').isEmpty
        ? '本表只登记插件信息，不审核、不托管插件文件，也不保证插件安全。'
            '插件由各自作者开发和发布，安装与使用风险自负。'
        : disclaimer!;
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

  /// 安装失败的兜底出口：复制原始地址 / 改用本地 zip。
  Future<void> _showFailure(
      BuildContext context, PluginRegistryException e) async {
    if (!context.mounted) return;
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
                if (context.mounted) _toast(context, '下载地址已复制');
              },
              child: const Text('复制下载地址'),
            ),
          if (onInstallFromFile != null)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                onInstallFromFile!.call();
              },
              child: const Text('从本地安装'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
