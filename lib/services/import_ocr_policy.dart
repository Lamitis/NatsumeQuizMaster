/// 导入 OCR 策略（v1.41）：**先看文字层，再决定要不要 OCR**。
///
/// 旧逻辑有两个坑：
/// 1. 用户要手动开 MinerU，但「开没开」与「这份 PDF 到底是不是扫描件」无关；
/// 2. 判定用整册字符数 < 200 兜底，电子版试卷前几页正常、末页附录少字也会
///    被拖去跑一遍几分钟的 OCR，看起来就像卡死。
///
/// 现在改成：**前 [samplePages] 页文字层抽样 → 平均每页 < [minCharsPerPage]
/// 字或整片乱码 → 判为扫描件**，扫描件才触发 MinerU；电子版直接走文本切块。
/// 判定与平台门禁都收在这个纯函数里，UI 与服务层共用，避免两处口径漂移。
class ImportOcrPolicy {
  ImportOcrPolicy._();

  /// 抽样页数：前 2~3 页足够判断「有没有文字层」，再读就是浪费
  static const int samplePages = 3;

  /// 扫描件阈值：抽样页平均每页少于 50 个字（含空白页）视为没文字层
  static const int minCharsPerPage = 50;

  /// 文本是否「够用」：低于这个字数当作不可用，转 OCR / 视觉切题
  static const int minUsableChars = 100;

  // ======================== 状态文案（UI / 测试共用） ========================

  /// 正在抽样检测文字层
  static String detectingTextLayer([int pages = samplePages]) =>
      '正在检测 PDF 文字层（前 $pages 页）…';

  /// 普通（非扫描件）PDF：本地抽图文
  static const String layoutExtracting = '正在提取图文排版…';

  /// 普通路径：文本切块 + AI 解析
  static const String chunking = '正在切块解析题目…';

  /// 普通路径的块级进度
  static String chunkingProgress(int done, int total) =>
      '正在切块解析题目…（$done/$total 块）';

  /// 判定为扫描件、即将交给 MinerU
  static const String mineruStarting = '检测到扫描件，正在使用 MinerU 识别版面…';

  /// MinerU 页面级进度（后端返回 extract_progress 时显示页码）
  static String mineruPage(int done, int total) =>
      '正在使用 MinerU 识别第 $done/$total 页版面…';

  /// MinerU 解析完成，正在下载/整理 Markdown
  static const String mineruDownloading = '正在提取图文排版…';

  /// MinerU 成功、转入 AI 切题
  static const String mineruChunking = 'MinerU 版面识别完成，正在切块解析题目…';

  /// MinerU 失败/超时：明确告知「已降级」，不阻塞导入
  static const String mineruFallback = 'MinerU 版面识别失败，已回退至普通文本提取模式';

  /// 桌面端但用户没开 MinerU：走本地 OCR / 视觉，不冒充「失败」
  static const String mineruDisabled = '未开启 MinerU，已改走本地 OCR / 视觉切题';

  /// 移动端：MinerU 不适用，走端上 OCR / 视觉切题
  static const String mobileFallback = '移动端不支持 MinerU，已改走端上 OCR / 视觉切题';

  /// 非 Windows 桌面端（Mac/Linux）：MinerU 不作为支持平台
  static const String platformUnsupported = '当前平台不支持 MinerU，已改走本地 OCR / 视觉切题';

  // ======================== 判定 ========================

  /// 抽样结果是否说明「这是扫描件/图片字 PDF」。
  ///
  /// - [garbled]：整片乱码（替换符 / 私用区 / 控制字符占比高）——有字也读不懂，
  ///   和没有文字层一样需要 OCR；
  /// - 平均每页少于 [minCharsPerPage] 个字（页数按实际抽样页算，空页也计入）。
  static bool isScannedPdf({
    required int charCount,
    required int sampledPages,
    required bool garbled,
  }) {
    if (garbled) return true;
    if (sampledPages <= 0) return true;
    return charCount / sampledPages < minCharsPerPage;
  }

  /// 是否该调用 MinerU。
  ///
  /// 三个条件缺一不可：**Windows 桌面端**（`Platform.isWindows`；移动端/
  /// 其他桌面端强制走离线 OCR/视觉）、**用户已开启**（上传第三方服务需要
  /// 明确同意）、**判定为扫描件**（电子版绝不白跑一趟 OCR）。
  static bool shouldUseMineru({
    required bool isWindows,
    required bool enabled,
    required bool needsOcr,
  }) =>
      isWindows && enabled && needsOcr;

  /// 文本是否达到「可切题」的字数
  static bool isUsableText(String text) =>
      text.trim().length >= minUsableChars;
}
