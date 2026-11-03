import 'package:flutter/material.dart';

import '../../services/import_ocr_policy.dart';
import '../../services/theme_service.dart';
import '../../utils/design_tokens.dart';
import '../kit/natsume_kit.dart';

/// 导入进度卡（v1.41）：导入页与「导入预览」页共用。
///
/// 需求是「让用户随时知道现在在干什么、还要多久」——尤其是 MinerU 动辄
/// 几十秒到几分钟。卡片把三件事放在一眼能看到的层级：
/// 1. 百分比 + 进度条（[NatsumeProgress]）；
/// 2. 当前阶段徽章（检测文字层 / MinerU 版面识别 / 端上 OCR / 文本切块）；
/// 3. 原始状态文案（含页码，如「正在使用 MinerU 识别第 3/12 页版面…」）。
class ImportProgressCard extends StatelessWidget {
  const ImportProgressCard({
    super.key,
    required this.progress,
    required this.status,
    this.title = '正在解析导入文档',
    this.onCancel,
    this.compact = false,
  });

  /// 0..1
  final double progress;

  /// AppState.importStatus 原文
  final String status;

  /// 卡片标题（预览页可改成「后台继续解析其余文档」）
  final String title;

  /// 取消（null = 此入口不可取消）
  final VoidCallback? onCancel;

  /// 紧凑模式：预览页横幅用，减少上下留白
  final bool compact;

  /// 从状态原文推断阶段，给用户一个「现在在哪一步」的短标签。
  static String phaseOf(String status) {
    if (status.contains('MinerU')) return 'MinerU 版面识别';
    if (status.contains('视觉')) return '视觉切题';
    if (status.contains('OCR') || status.contains('识别扫描页')) return '端上 OCR';
    if (status.contains('切块')) return '文本切块';
    if (status.contains('文字层')) return '检测文字层';
    if (status.contains('提取')) return '提取图文';
    if (status.contains('准备') || status.contains('整理')) return '准备';
    return '解析中';
  }

  /// 是否处于「MinerU 可能触发」的阶段（给进度条换色，视觉上提示走的是慢路径）
  static bool isMineruPhase(String status) => status.contains('MinerU');

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final pct = progress.clamp(0.0, 1.0);
    final phase = phaseOf(status);
    final mineru = isMineruPhase(status);
    return NatsumeSurface(
      accentEdge: true,
      padding: EdgeInsets.all(compact ? NatsumeSpace.xs + 2 : NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: mineru ? ac.warning : ac.accent),
              ),
              const SizedBox(width: NatsumeSpace.xs),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NatsumeType.h3Style.copyWith(
                      fontWeight: FontWeight.w600, color: ac.textPrimary),
                ),
              ),
              NatsumeNumber('${(pct * 100).toInt()}',
                  size: NatsumeType.h3, weight: FontWeight.w600),
              Text('%',
                  style: NatsumeType.microStyle
                      .copyWith(color: ac.textSecondary)),
            ],
          ),
          const SizedBox(height: NatsumeSpace.xs),
          NatsumeProgress(value: pct, color: mineru ? ac.warning : null),
          const SizedBox(height: NatsumeSpace.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NatsumeTag(phase,
                  tone: mineru
                      ? NatsumeTagTone.warning
                      : NatsumeTagTone.accent),
              const SizedBox(width: NatsumeSpace.xs),
              Expanded(
                child: Text(
                  status.isEmpty ? ImportOcrPolicy.chunking : status,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textSecondary, height: 1.45),
                ),
              ),
              if (onCancel != null) ...[
                const SizedBox(width: NatsumeSpace.xs),
                NatsumeButton(
                  label: '取消',
                  kind: NatsumeButtonKind.ghost,
                  dense: true,
                  onPressed: onCancel,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
