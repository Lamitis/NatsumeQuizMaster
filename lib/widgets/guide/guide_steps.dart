import 'guide_step.dart';

export 'guide_step.dart';

/// 引导锚点 id（与 `GuideAnchor(id: ...)` 一一对应）
///
/// 集中定义：步骤文案与锚点挂载点分处不同文件，靠常量对齐。
/// 写错 id 的后果是「这一步没有洞」——由 `GuideTour` 的兜底处理收住，不会崩。
class GuideAnchorIds {
  GuideAnchorIds._();

  /// 底部导航 / 侧边导航（两种宽屏形态共用同一 id）
  static const String shellNav = 'shell.nav';

  /// 首页「本周战绩」卡
  static const String homeWeekly = 'home.weekly';

  /// 首页问候 / 总进度 / 断点续刷固定块
  static const String homeHero = 'home.hero';

  /// 开始页「导入题库」入口
  static const String quickImport = 'quick.import';

  /// 开始页「定向爆破」（开始刷题）主行动
  static const String quickPrimary = 'quick.primary';

  /// 开始页「错题本」入口
  static const String quickErrorBook = 'quick.errorbook';

  /// 统计页顶部概览区
  static const String statsOverview = 'stats.overview';

  /// 我的页「设置」入口
  static const String profileSettings = 'profile.settings';

  /// 错题本页左上角返回（加载 / 空态 / 有数据三态恒存在）
  static const String errorbookBack = 'errorbook.back';

  /// 错题本「薄弱知识点」标签云（有错题数据时才有）
  static const String errorbookKnowledge = 'errorbook.knowledge';

  /// 错题本空态（首启没有错题时，用来解释知识点标签）
  static const String errorbookEmpty = 'errorbook.empty';

  /// 设置中心页左上角返回
  static const String settingsBack = 'settings.back';

  /// 设置 → AI 接口页的 API Key 输入框
  static const String settingsApiKey = 'settings.apikey';

  /// 我的页「学习工具」分组标题
  static const String profileLearningTools = 'profile.tools';

  /// 我的页「双链笔记」入口
  static const String profileNotes = 'profile.notes';

  /// 我的页「小鲸助教」入口
  static const String profileCompanion = 'profile.companion';

  /// 导入页「一键导入示例题库」（二级页锚点）
  static const String importSample = 'import.sample';

  /// 「开始刷题」弹窗里的最终确认按钮「开始」（弹层锚点）
  static const String sheetConfirm = 'sheet.confirm';
}

/// 首启引导步骤（v1.39 · 7 步精简版）
///
/// 只走「第一次必须知道」的路径：首页总览 → 五个 Tab → 配置 API Key →
/// 导入题库 → 刷题与 AI 解析 → 错题本知识点标签 → 双链笔记 & 小鲸助教。
///
/// 其中「配置 API Key」「错题本标签」两层在二级页里，用 [GuideStep.destination]
/// 由根节点打开对应页面（路由注入见 `main.dart`），下一步会自动 pop 回主壳并切
/// Tab——不让用户困在二级页里找不到下一步的高亮。
///
/// [GuideStep.awaitAction] 的「用户点高亮处自己进去」能力仍保留，供后续步骤
/// 需要真实操作时使用；本版不强制用户操作，全部可「下一步 / 跳过」。
const List<GuideStep> kGuideSteps = [
  GuideStep(
    title: '你的备考驾驶舱',
    body: 'NatsumeQuizMaster 是本地优先的 AI 刷题工具：题库、错题、统计都在本机。'
        '首页先回答「我现在到哪了、接下来做什么」——这里是总进度，'
        '下面还有断点续刷与本周战绩。',
    tab: 0,
    anchorId: GuideAnchorIds.homeHero,
  ),
  GuideStep(
    title: '五个板块分工明确',
    body: '「首页」看进度、「开始」导入与刷题、「统计」看正确率与热力图、'
        '「我的」做设置与学习工具、「世界」管理世界包与插件。'
        '接下来按顺序看最关键的几处。',
    // 必须声明 tab：IndexedStack 的未选中页每帧照常布局，不声明可能把洞
    // 打到用户看不见的那一页坐标上。
    anchorId: GuideAnchorIds.shellNav,
  ),
  GuideStep(
    title: '先填 API Key（关键）',
    body: '填入 API Key 即可解锁 AI 解析和出题；不填也能正常刷题、看自带解析。'
        'Key 只保存在本机，这一页还能选模型与回答风格。',
    tab: 3,
    destination: GuideDestination.settingsAi,
    anchorId: GuideAnchorIds.settingsApiKey,
  ),
  GuideStep(
    title: '导入题库',
    body: 'JSON 直接入库；DOCX / PDF 可用 AI 解析成题（需 API Key）。'
        '第一次用也可以先导入内置示例题库试手。',
    tab: 1,
    anchorId: GuideAnchorIds.quickImport,
  ),
  GuideStep(
    title: '刷题与 AI 解析（核心）',
    body: '点「自由选题」开始刷题。答完一题后，解析区可以生成 AI 逐题讲解、'
        '高亮关键词，还能继续「向 AI 追问」——这是本工具最核心的卖点。',
    tab: 1,
    anchorId: GuideAnchorIds.quickPrimary,
  ),
  GuideStep(
    title: '错题本：按知识点标签复习',
    body: '答错的题会按记忆曲线排期。错题本顶部的「薄弱知识点」按标签分组，'
        '点任一标签就能只复习这一类。没有错题时这里会先显示空态，'
        '刷几轮再回来看；看完点「下一步」会自动回到主界面。',
    tab: 1,
    destination: GuideDestination.errorBook,
    anchorId: GuideAnchorIds.errorbookKnowledge,
    fallbackAnchorIds: [
      GuideAnchorIds.errorbookEmpty,
      GuideAnchorIds.errorbookBack,
    ],
  ),
  GuideStep(
    title: '双链笔记 & 小鲸助教',
    body: '「我的 → 学习工具」里还有两个特色插件：双链笔记用 [[双链]] 记灵感，'
        '小鲸助教按连胜与正确率陪你学。到这儿就上手了，'
        '之后随时可以在「我的」里重看这段引导。',
    tab: 3,
    anchorId: GuideAnchorIds.profileNotes,
    fallbackAnchorIds: [
      GuideAnchorIds.profileCompanion,
      GuideAnchorIds.profileLearningTools,
    ],
    nextLabel: '完成',
  ),
];
