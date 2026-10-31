import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/import_source_filter.dart';

/// 桌面端拖拽导入容器（v1.35.4 入口优化）。
///
/// 只在 Windows / macOS / Linux 上挂 [DropTarget]；移动端与 widget 测试
/// （`defaultTargetPlatform` 为 android）直接返回 [child]，行为与引入前一致。
///
/// 本组件只负责「展开文件夹 + 过滤格式 + 去重」，过滤结果交给 [onFiles]；
/// 解析与排队预览仍由 `AppState.startBackgroundImport` → `parseForPreview`
/// 负责，预览队列逻辑一行没动。
class ImportDropZone extends StatefulWidget {
  const ImportDropZone({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
  });

  final Widget child;

  /// 拖拽落地回调（已过滤、去重）
  final ValueChanged<ImportSourceCollectResult> onFiles;

  /// 是否接受拖拽（导入进行中应关掉，避免叠加任务）
  final bool enabled;

  /// 当前平台是否真的支持拖拽（仅桌面三端；本项目不构建 web）
  static bool get isDesktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  State<ImportDropZone> createState() => _ImportDropZoneState();
}

class _ImportDropZoneState extends State<ImportDropZone> {
  bool _hovering = false;
  bool _collecting = false;

  void _setHovering(bool value) {
    if (!mounted || _hovering == value) return;
    setState(() => _hovering = value);
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    _setHovering(false);
    if (!mounted || !widget.enabled || _collecting) return;
    // desktop_drop 的已知行为：DropTarget 被新页面盖住时仍会收到拖拽事件
    //（见其 README 的 enable 说明 / issues#2）。落地前再确认本页在最上层，
    // 避免「在别的页面上拖文件却触发了导入」。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _collecting = true;
    try {
      final result = await ImportSourceFilter.collect(
          details.files.map((f) => f.path));
      if (!mounted) return;
      widget.onFiles(result);
    } finally {
      _collecting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ImportDropZone.isDesktopPlatform) return widget.child;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setHovering(true),
      onDragExited: (_) => _setHovering(false),
      onDragDone: _handleDrop,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_hovering) const Positioned.fill(child: _DropOverlay()),
        ],
      ),
    );
  }
}

/// 拖拽悬停时的整页蒙层：「松开以批量导入」
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return IgnorePointer(
      child: Container(
        color: ac.background.withOpacity(0.85),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(NatsumeSpace.xl),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: NatsumeSpace.xl, vertical: NatsumeSpace.lg),
          decoration: BoxDecoration(
            color: ac.surface,
            borderRadius: BorderRadius.circular(NatsumeRadius.large),
            border: Border.all(color: ac.accent, width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.file_download_outlined, size: 44, color: ac.accent),
              const SizedBox(height: NatsumeSpace.sm),
              Text('松开以批量导入',
                  style: NatsumeType.h2Style.copyWith(
                      color: ac.accent, fontWeight: FontWeight.w600)),
              const SizedBox(height: NatsumeSpace.xxs),
              Text('支持 JSON / DOCX / PDF；拖入文件夹会递归查找其中的文件',
                  textAlign: TextAlign.center,
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
