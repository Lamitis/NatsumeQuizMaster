import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import 'kit/natsume_kit.dart';

/// Giscus 评论区参数（v1.36）。
///
/// Giscus = 把仓库的 GitHub Discussions 嵌进页面，参数由
/// https://giscus.app 生成（repo / repo-id / category / category-id 四项必填）。
@immutable
class GiscusConfig {
  const GiscusConfig({
    this.repo = '',
    this.repoId = '',
    this.category = '',
    this.categoryId = '',
    this.mapping = 'pathname',
    this.theme = 'preferred_color_scheme',
    this.lang = 'zh-CN',
  });

  /// `owner/repo`（讨论区所在的仓库，可以不等于插件仓库）
  final String repo;

  /// `data-repo-id`
  final String repoId;

  /// 讨论分类名，例如 `Announcements`
  final String category;

  /// `data-category-id`
  final String categoryId;

  /// `pathname` / `url` / `title` 等，默认按页面路径映射
  final String mapping;

  /// giscus 主题（`preferred_color_scheme` 会跟随系统深浅色）
  final String theme;

  final String lang;

  /// 四项 id 齐了才算配置好：Giscus 少一个都不渲染，半配的配置等于白屏
  bool get isConfigured =>
      repo.trim().isNotEmpty &&
      repoId.trim().isNotEmpty &&
      category.trim().isNotEmpty &&
      categoryId.trim().isNotEmpty;

  static const GiscusConfig none = GiscusConfig();

  /// ⚠️ **待填**：把 giscus.app 生成的四个参数填进这里，详情页就会渲染真实评论区。
  ///
  /// 保持空串时详情页**不渲染 WebView**，只显示「前往 GitHub 讨论区」按钮
  /// （见 [PluginDiscussion] 的兜底分支）——宁可给个能用的出口，也不要白屏。
  static const GiscusConfig current = GiscusConfig();

  /// Giscus 的嵌入文档。
  ///
  /// `loadHtmlString` 的文档本身没有源（about:blank），Giscus 的 iframe 依赖
  /// postMessage 与父页面通信，所以调用方要给它一个真实 baseUrl（`https://giscus.app/`）。
  String htmlDocument({String background = 'transparent'}) {
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body { margin: 0; padding: 0; background: $background;
               font-family: -apple-system, "Segoe UI", Roboto, sans-serif; }
  .wrap { padding: 4px; }
</style>
</head>
<body>
<div class="wrap">
<script src="https://giscus.app/client.js"
        data-repo="${_attr(repo)}"
        data-repo-id="${_attr(repoId)}"
        data-category="${_attr(category)}"
        data-category-id="${_attr(categoryId)}"
        data-mapping="${_attr(mapping)}"
        data-strict="0"
        data-reactions-enabled="1"
        data-emit-metadata="0"
        data-input-position="bottom"
        data-theme="${_attr(theme)}"
        data-lang="${_attr(lang)}"
        crossorigin="anonymous"
        async>
</script>
</div>
</body>
</html>
''';
  }
}

/// 详情页底部的讨论区（v1.36）。
///
/// 三种形态，按「能不能用」依次退化：
/// 1. 参数已填 + 平台有 WebView 实现 → 内嵌 Giscus 评论区；
/// 2. 参数已填但 WebView 起不来（Windows / Linux 没有实现，或初始化抛异常）
///    → 一行说明 + 「前往 GitHub 讨论区」；
/// 3. 参数没填 → 同样的出口按钮（默认指向插件仓库的 `/discussions`）。
///
/// 为什么不给 WebView 自适应高度：本组件位于可滚动列表里，无界高度会直接崩，
/// 所以固定 [height]，评论在 WebView 内部滚动。
class PluginDiscussion extends StatefulWidget {
  const PluginDiscussion({
    super.key,
    this.config = GiscusConfig.current,
    this.fallbackUrl,
    this.onOpenLink,
    this.webViewAvailable,
    this.height = 420,
  });

  final GiscusConfig config;

  /// 兜底按钮的目标地址（一般传 `<repo_url>/discussions`）
  final String? fallbackUrl;

  /// 外链打开方式（详情页传自己的实现，好统一提示「没有可用浏览器」）
  final Future<void> Function(String url)? onOpenLink;

  /// 强制指定 WebView 可用性（widget 测试传 false，避免碰真平台通道）
  final bool? webViewAvailable;

  /// WebView 固定高度（必须给，列表里高度无界）
  final double height;

  /// 平台层面有没有 WebView 实现（webview_flutter 只有 Android / iOS）
  static bool platformSupportsWebView() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  State<PluginDiscussion> createState() => _PluginDiscussionState();
}

class _PluginDiscussionState extends State<PluginDiscussion> {
  WebViewController? _controller;
  bool _loading = false;

  /// 退化成外链的原因（空 = 没退）
  String? _degraded;

  bool get _webViewUsable =>
      widget.webViewAvailable ?? PluginDiscussion.platformSupportsWebView();

  @override
  void initState() {
    super.initState();
    if (_webViewUsable && widget.config.isConfigured) {
      _initWebView();
    } else {
      _degraded = widget.config.isConfigured
          ? '这台设备没有可用的 WebView，评论区改成在浏览器里打开。'
          : 'Giscus 参数还没配置，评论区改成在浏览器里打开。';
    }
  }

  Future<void> _initWebView() async {
    setState(() => _loading = true);
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent);
      await controller.loadHtmlString(
        widget.config.htmlDocument(),
        // 给文档一个真实来源，Giscus 的 iframe 才敢跨窗口通信
        baseUrl: 'https://giscus.app/',
      );
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _degraded = '评论区加载失败（$e），可以到浏览器里看。';
      });
    }
  }

  Future<void> _openFallback() async {
    final url = (widget.fallbackUrl ?? '').trim();
    if (url.isEmpty) return;
    final open = widget.onOpenLink;
    if (open != null) {
      await open(url);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final hasFallback = (widget.fallbackUrl ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const NatsumeSectionHeader(
          title: '讨论区',
          subtitle: 'Giscus · 基于仓库的 GitHub Discussions，登录 GitHub 才能发言',
        ),
        const SizedBox(height: NatsumeSpace.xs),
        if (_controller != null)
          Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: ac.surfaceAlt,
              borderRadius: BorderRadius.circular(NatsumeRadius.card),
              border: Border.all(color: ac.border, width: NatsumeLine.width),
            ),
            clipBehavior: Clip.antiAlias,
            child: WebViewWidget(controller: _controller!),
          )
        else if (_loading)
          SizedBox(
            height: widget.height,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          _fallback(ac, hasFallback),
      ],
    );
  }

  Widget _fallback(AppThemeColors ac, bool hasFallback) {
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.forum_outlined, size: 16, color: ac.textSecondary),
              const SizedBox(width: NatsumeSpace.xxs),
              Text('评论在这里看不了',
                  style: NatsumeType.captionStyle.copyWith(
                      color: ac.textPrimary, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xxs),
          Text(
            _degraded ?? '评论区暂时不可用。',
            style: NatsumeType.microStyle
                .copyWith(color: ac.textSecondary, height: 1.5),
          ),
          if (hasFallback) ...[
            const SizedBox(height: NatsumeSpace.xs),
            NatsumeButton(
              label: '前往 GitHub 讨论区',
              dense: true,
              kind: NatsumeButtonKind.secondary,
              icon: Icons.open_in_new_rounded,
              onPressed: _openFallback,
            ),
          ],
        ],
      ),
    );
  }
}

/// HTML 属性值转义：配置是代码里写的常量，但仍然不拼接裸值
String _attr(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
