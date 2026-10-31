import 'package:flutter/material.dart';

import '../models/question.dart';
import '../services/app_state.dart';
import '../services/quiz_launcher.dart';
import '../services/theme_service.dart';
import '../utils/app_constants.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import 'guide/guide_anchor.dart';
import 'guide/guide_steps.dart';
import 'kit/natsume_kit.dart';

/// 「自由选题」面板的确认结果。
///
/// 题库范围 / 知识点 / 题型 / 题量 / 模式一次交出，调用方只管把它喂给
/// [QuizLauncher]——面板内改范围**不写回** `AppState.selectedBankIds`，
/// 免得「临时只想刷这一库」把开始页的勾选状态悄悄改掉。
class QuizSetupResult {
  const QuizSetupResult({
    required this.bankIds,
    required this.count,
    required this.mode,
    this.knowledgePoints = const <String>{},
    this.questionTypes = const <String>{},
    this.noShuffle = false,
  });

  /// 本次抽题的题库范围（至少一个）
  final Set<int> bankIds;

  /// 知识点筛选；**空集合 = 不限**（等价于整库）
  final Set<String> knowledgePoints;

  /// 题型筛选；空集合 = 不限
  final Set<String> questionTypes;

  /// 每轮题数（可能是 [kQuestionCountAll] 这个「全部」哨兵）
  final int count;

  final QuizLaunchMode mode;

  /// 按题库原顺序出题（不做随机）
  final bool noShuffle;

  /// 是否用到了筛选条件：用于「该条件下暂无题目」这类更准确的提示
  bool get hasFilter => knowledgePoints.isNotEmpty || questionTypes.isNotEmpty;
}

/// 自由选题面板：**题库范围 → 知识点 → 题型 → 题量 → 模式**，
/// 一次确认开刷。
///
/// 题库范围只能回「管理题库」提前勾好，一换知识点就得
/// 回去重勾。现在范围、知识点都在这张面板里选，勾选结果只作用于本次抽题。
///
/// 与题库题号网格共用 [QuizLaunchMode] 三种模式的定义，两边文案不会漂移。
class QuizSetupSheet extends StatefulWidget {
  const QuizSetupSheet({super.key, required this.appState});

  final AppState appState;

  /// 弹出面板；用户点「开始」时返回 [QuizSetupResult]，取消返回 null。
  static Future<QuizSetupResult?> show(BuildContext context, AppState appState) =>
      NatsumeSheet.show<QuizSetupResult>(
        context,
        title: '自由选题',
        maxWidth: kSheetMaxWidth,
        child: QuizSetupSheet(appState: appState),
      );

  @override
  State<QuizSetupSheet> createState() => _QuizSetupSheetState();
}

class _QuizSetupSheetState extends State<QuizSetupSheet> {
  /// 面板内的题库范围：默认沿用开始页的勾选；**什么都没勾时默认全选**，
  /// 这样直接点「自由选题」也能一次「开始」就开刷，与知识点「不选 = 全部」
  /// 是同一口径。
  late final Set<int> _bankIds = _initialBankIds();

  Set<int> _initialBankIds() {
    final selected = widget.appState.selectedBankIds;
    if (selected.isNotEmpty) return <int>{...selected};
    return <int>{
      for (final b in widget.appState.banks)
        if (b.id != null) b.id!,
    };
  }

  /// 已选知识点（空 = 不限）
  final Set<String> _kps = <String>{};

  /// 已选题型（空 = 不限）。code 与 `Question.questionType` 同值
  final Set<String> _types = <String>{};

  /// 面板里可筛的七种题型（顺序：常见 → 长答）
  static const List<String> _typeCodes = [
    'single_choice',
    'multi_choice',
    'true_false',
    'fill_blank',
    'ming_jie',
    'jian_da',
    'jie_da',
  ];

  late int _count = widget.appState.selectedQuestionCount;
  bool _custom = false;
  bool _noShuffle = false;
  QuizLaunchMode _mode = QuizLaunchMode.quiz;

  final TextEditingController _customCtrl = TextEditingController();

  /// 当前题库范围下的知识点分布；null = 加载中
  List<Map<String, dynamic>>? _kpStats;

  /// 加载代次：连续切题库时只认最后一次结果，防止旧结果覆盖新范围
  int _kpLoadToken = 0;

  @override
  void initState() {
    super.initState();
    _loadKnowledgePoints();
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKnowledgePoints() async {
    final token = ++_kpLoadToken;
    final ids = _bankIds.toList();
    List<Map<String, dynamic>> stats = const <Map<String, dynamic>>[];
    if (ids.isNotEmpty) {
      stats = await widget.appState.getKnowledgePointsByBanks(ids.toSet());
    }
    if (!mounted || token != _kpLoadToken) return;
    setState(() {
      _kpStats = stats;
      // 换了题库范围后，已选知识点可能已经不存在：只留交集，
      // 否则会出现「看着勾着、实际筛出 0 题」
      final available = stats.map((e) => e['kp'] as String? ?? '').toSet();
      _kps.removeWhere((k) => !available.contains(k));
    });
  }

  /// 改题库范围后知识点列表要跟着刷新（联动）
  void _applyBanks(void Function() change) {
    setState(() {
      change();
      _kpStats = null; // 进入加载态，避免旧范围的标签被误点
    });
    _loadKnowledgePoints();
  }

  void _toggleBank(int id) => _applyBanks(() {
        if (!_bankIds.remove(id)) _bankIds.add(id);
      });

  void _selectAllBanks() => _applyBanks(() {
        _bankIds
          ..clear()
          ..addAll([
            for (final b in widget.appState.banks)
              if (b.id != null) b.id!,
          ]);
      });

  void _invertBanks() => _applyBanks(() {
        final next = <int>{
          for (final b in widget.appState.banks)
            if (b.id != null && !_bankIds.contains(b.id)) b.id!,
        };
        _bankIds
          ..clear()
          ..addAll(next);
      });

  /// 已选题库的题数合计（「已选 N 库 M 题」的 M）
  int get _selectedQuestionTotal {
    var total = 0;
    for (final b in widget.appState.banks) {
      if (b.id != null && _bankIds.contains(b.id)) total += b.questionCount;
    }
    return total;
  }

  /// 解析最终题数；自定义输入非法时返回 null（面板不关，提示后继续改）
  int? get _resolvedCount {
    if (!_custom) {
      return _count >= kQuestionCountAll ? kQuestionCountAll : _count;
    }
    final n = int.tryParse(_customCtrl.text.trim());
    return (n == null || n <= 0) ? null : n;
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    // 五段内容（题库范围 / 知识点 / 题型 / 题量 / 模式）在小屏会超过一屏：
    // 弹层内部滚动，标题与「开始」始终可达。
    // 上限从 0.66 提到 0.78：v1.34 加了题型一段，若还按 0.66，420×900 上
    // 「开始」会被挤到折叠线以下——首启引导的最后一步正指着这个按钮。
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label('题库范围 · 已选 ${_bankIds.length} 库 $_selectedQuestionTotal 题', ac),
            const SizedBox(height: NatsumeSpace.sm),
            Wrap(
              spacing: NatsumeSpace.xs,
              runSpacing: NatsumeSpace.xs,
              children: [
                NatsumeChip(
                    label: '全选',
                    dense: true,
                    selected: false,
                    onTap: _selectAllBanks),
                NatsumeChip(
                    label: '反选',
                    dense: true,
                    selected: false,
                    onTap: _invertBanks),
                NatsumeChip(
                    label: '清空',
                    dense: true,
                    selected: false,
                    onTap: () => _applyBanks(_bankIds.clear)),
              ],
            ),
            const SizedBox(height: NatsumeSpace.xs),
            Wrap(
              spacing: NatsumeSpace.xs,
              runSpacing: NatsumeSpace.xs,
              children: [
                for (final b in widget.appState.banks)
                  if (b.id != null)
                    NatsumeChip(
                      label: '${b.name} · ${b.questionCount}',
                      dense: true,
                      selected: _bankIds.contains(b.id),
                      onTap: () => _toggleBank(b.id!),
                    ),
              ],
            ),
            const SizedBox(height: NatsumeSpace.md),
            _label('知识点（不选 = 全部）', ac),
            const SizedBox(height: NatsumeSpace.sm),
            _buildKnowledgePoints(ac),
            const SizedBox(height: NatsumeSpace.md),
            _label('题型（不选 = 全部）', ac),
            const SizedBox(height: NatsumeSpace.sm),
            _buildQuestionTypes(ac),
            const SizedBox(height: NatsumeSpace.md),
            _label('每轮题数', ac),
            const SizedBox(height: NatsumeSpace.sm),
            Wrap(
              spacing: NatsumeSpace.xs,
              runSpacing: NatsumeSpace.xs,
              children: [
                for (final n in const [10, 20, 30, 50, 80, 100])
                  NatsumeChip(
                    label: '$n 题',
                    dense: true,
                    selected: !_custom && _count == n,
                    onTap: () => setState(() {
                      _custom = false;
                      _count = n;
                    }),
                  ),
                NatsumeChip(
                  label: '全部',
                  dense: true,
                  selected: !_custom && _count >= kQuestionCountAll,
                  onTap: () => setState(() {
                    _custom = false;
                    _count = kQuestionCountAll;
                  }),
                ),
                NatsumeChip(
                  label: '自定义',
                  dense: true,
                  selected: _custom,
                  onTap: () => setState(() => _custom = true),
                ),
              ],
            ),
            if (_custom) ...[
              const SizedBox(height: NatsumeSpace.sm),
              TextField(
                controller: _customCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '输入题数'),
                style: const TextStyle(fontSize: NatsumeType.body),
              ),
            ],
            const SizedBox(height: NatsumeSpace.md),
            _label('刷题模式', ac),
            for (final mode in QuizLaunchMode.values) _modeRow(mode, ac),
            const SizedBox(height: NatsumeSpace.md),
            _buildOrderRow(ac),
            const SizedBox(height: NatsumeSpace.md),
            // 首启引导的最后一步落在这个按钮上：用户在真实弹窗里点「开始」，
            // 引导就带着他走完了「导入 → 刷题」全程（随后的页面跳转即收尾）
            GuideAnchor(
              id: GuideAnchorIds.sheetConfirm,
              child: NatsumeButton(
                label: '开始',
                expand: true,
                onPressed: _confirm,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 知识点区三态：加载中 / 没有标签 / 可选标签
  Widget _buildKnowledgePoints(AppThemeColors ac) {
    final stats = _kpStats;
    if (stats == null) {
      return Text('正在读取知识点…',
          style: NatsumeType.captionStyle.copyWith(color: ac.textTertiary));
    }
    if (stats.isEmpty) {
      return Text('所选题库还没有知识点标签，可直接按整库刷题',
          style: NatsumeType.captionStyle.copyWith(color: ac.textTertiary));
    }
    return Wrap(
      spacing: NatsumeSpace.xs,
      runSpacing: NatsumeSpace.xs,
      children: [
        NatsumeChip(
          label: '全部知识点',
          dense: true,
          selected: _kps.isEmpty,
          onTap: () => setState(_kps.clear),
        ),
        for (final s in stats)
          Builder(builder: (_) {
            final kp = s['kp'] as String? ?? '';
            final cnt = s['cnt'] as int? ?? 0;
            return NatsumeChip(
              // 空知识点在界面上叫「未分类」（与错题本「未打标签」同义）
              label: '${kp.isEmpty ? '未分类' : kp} · $cnt',
              dense: true,
              selected: _kps.contains(kp),
              onTap: () => setState(() {
                if (!_kps.remove(kp)) _kps.add(kp);
              }),
            );
          }),
      ],
    );
  }

  /// 题型区：七种题型全列（题库里没有的题型选中也无害，只是筛出 0 题会被
  /// 「该条件下暂无题目」拦在开刷之前）
  Widget _buildQuestionTypes(AppThemeColors ac) {
    return Wrap(
      spacing: NatsumeSpace.xs,
      runSpacing: NatsumeSpace.xs,
      children: [
        NatsumeChip(
          label: '全部题型',
          dense: true,
          selected: _types.isEmpty,
          onTap: () => setState(_types.clear),
        ),
        for (final code in _typeCodes)
          NatsumeChip(
            label: Question.labelOfType(code),
            dense: true,
            selected: _types.contains(code),
            onTap: () => setState(() {
              if (!_types.remove(code)) _types.add(code);
            }),
          ),
      ],
    );
  }

  /// 顺序 / 随机（背题模式恒按原顺序，开关置灰）
  Widget _buildOrderRow(AppThemeColors ac) {
    final locked = _mode == QuizLaunchMode.memorize;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('按题库原顺序出题',
                  style: NatsumeType.h3Style.copyWith(
                      fontWeight: FontWeight.w600, color: ac.textPrimary)),
              const SizedBox(height: 2),
              Text(
                locked ? '背题模式始终按原顺序' : '关闭时随机抽题',
                style:
                    NatsumeType.captionStyle.copyWith(color: ac.textSecondary),
              ),
            ],
          ),
        ),
        Switch(
          value: locked || _noShuffle,
          onChanged: locked ? null : (v) => setState(() => _noShuffle = v),
        ),
      ],
    );
  }

  /// 模式单选行：Linear 式小方块选择器（与题库选择/答题选项同一套语言）
  Widget _modeRow(QuizLaunchMode mode, AppThemeColors ac) {
    final selected = _mode == mode;
    return InkWell(
      onTap: () => setState(() => _mode = mode),
      borderRadius: NatsumeRadius.smallBorder,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NatsumeSpace.xs),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: selected ? ac.accent : Colors.transparent,
                border: Border.all(
                  color: selected ? ac.accent : ac.border,
                  width: 1.2,
                ),
                borderRadius: NatsumeRadius.chipBorder,
              ),
              child: selected
                  ? Icon(Icons.check_rounded, size: 12, color: ac.onAccent)
                  : null,
            ),
            const SizedBox(width: NatsumeSpace.sm),
            Icon(mode.icon,
                size: 18, color: selected ? ac.accent : ac.textSecondary),
            const SizedBox(width: NatsumeSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.label,
                      style: NatsumeType.h3Style.copyWith(
                          fontWeight: FontWeight.w600, color: ac.textPrimary)),
                  const SizedBox(height: 2),
                  Text(mode.description,
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text, AppThemeColors ac) => Text(text,
      style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary));

  /// 校验 → 关面板 → 把结果交回调用方
  void _confirm() {
    final count = _resolvedCount;
    if (count == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入大于 0 的有效题数')),
      );
      return;
    }
    if (_bankIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个题库')),
      );
      return;
    }
    Navigator.of(context).pop(QuizSetupResult(
      bankIds: {..._bankIds},
      knowledgePoints: {..._kps},
      questionTypes: {..._types},
      count: count,
      mode: _mode,
      noShuffle: _mode == QuizLaunchMode.memorize || _noShuffle,
    ));
  }
}
