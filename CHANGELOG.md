# 更新日志

本文件记录 NatsumeQuizMaster 的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

分类约定：`新增`（Features）/ `修复`（Bug Fixes）/ `重构`（Refactors），**每条一句话**。
写给用户看的生动说明放在对应 GitHub Release Notes，本文件只做事实索引。

> 版本号唯一来源是 `pubspec.yaml` 的 `version:` 字段，`kAppVersion` 与它由
> `test/version_single_source_test.dart` 守着。
> 1.34 及更早的逐条明细已压缩为文末「历史版本概览」。

---

## [1.35.4] - 2026-10-31

局域网同步收口：配对改成双向、失败有业务错误码、增量传输不再重传配图。

### 新增
- 「取消同步」按钮与「重置同步进度（下次全量）」入口。
- 题库内题目管理：搜索、筛选、编辑、移动、批量删除与新建。
- 知识库文档可重命名 / 跨库移动；MinerU 扫描件版面识别（默认关闭，需 Token）。

### 修复
- 配对只有单向（对端仍要求识别码）：新增 `POST /sync/pair` 双向握手。
- 同步失败后无限转圈：底层异常收敛为 `SyncException` 业务码，配 90s 看门狗与超时兜底。
- 同步极慢：修掉嵌套 `db.batch` 死锁，改按 `updated_at` 增量传，未变更题的配图不再重编码。
- 设置页「同步与提醒」分组缺块、分组卡片水波纹被底色遮挡。

### 重构
- 新增《插件 API 对接文档》与 `tools/publish_release.ps1` 一键发版；README 加 12 张界面截图；清理约 100 处废话 / 流水账注释。

## [1.35.3] - 2026-10-30

局域网同步在真机上暴露的三个问题逐个钉死。

### 新增
- 设置 → 同步新增「网络诊断」：进出包数、socket 重建次数、监听端口、最近错误。

### 修复
- 同一 Wi-Fi 发现不到设备：绑定 socket 后没开广播被系统销毁，改为广播 / 多播 / 单播三通道并用并自动重建。
- Windows 端错误展示扫码 UI：桌面端改为内嵌本机二维码，不再创建相机控制器。
- 识别码一存就显示「已配对」：改为 `awaitingPeer → verifying → verified` 状态机，握手通过才显示。
- 二维码写进虚拟网卡地址：统一过滤回环 / APIPA / CGNAT 与虚拟机、容器、VPN 网卡。

## [1.35.2] - 2026-10-30

Windows 构建与发布流水线收口。

### 修复
- Windows 构建报 C2440：`tools/patch_pub_cache.dart` 固化第三方源码补丁（幂等、支持 `--check`）。
- `kAppVersion` 默认值与 pubspec 不同步，导致版本单一来源测试变红。

### 重构
- `release.yml` 三处收口：Android 签名前置校验、Gradle 源改官方、Windows 依赖补丁先行。

## [1.35.1] - 2026-10-30

依赖大版本升级，Windows 编译报错从根源消掉。

### 修复
- `flutter_local_notifications` 22.x / `flutter_secure_storage` 11.x / `file_picker` 13.x 的 `ATL::CW2A` 冲突与 API 重写迁移。
- `ExportStorage.saveFileAs` 适配 `file_picker` 13.x 返回 `Uri` 的新语义。

### 重构
- Android 侧迁到声明式 Gradle 插件，`versionName` / `versionCode` 由 Flutter Gradle 插件从 pubspec 注入。
- 美术素材的授权边界写进 README 与 `THIRD_PARTY_NOTICES.md`。

## [1.35.0] - 2026-10-30

插件生态与学习闭环成型。

### 新增
- 题库分类树（schema v15）、导入 / 编辑时直接加图（统一 WebP）、解析与追问接入知识库。
- 自由选题支持题型筛选、AI 补全缺失答案、检查更新、日历当日待办、错题本批量删减。
- 日程待办插件、插件内容同步（schema v17）、助教形象、自定义知识点体系、Natsume-Registry 插件源。

### 修复
- 批量导入只解析第一份、题干配图顶出屏幕、题库无法改名、窄屏横向溢出等真机问题。

### 重构
- 导出统一改「另存为」；测试按进程隔离数据库，修掉偶发 SQLite 锁死。

## 历史版本概览

| 版本 | 日期 | 核心内容 |
|---|---|---|
| 1.33.0 | 2026-10-29 | 悬浮小鲸浮层、助教设置页（人格 / 接口 / 知识库 / 记忆）、对话记忆、知识库接地 |
| 1.32.0 | 2026-10-29 | 小鲸助教陪伴插件：数据驱动的 AI 角色，首个官方内置插件 |
| 1.31.0 | 2026-10-29 | 题库题号网格、Logseq 风格双链笔记插件、自由选题 |
| 1.29.0 | 2026-10-10 | Natsume Des 2.0 全新 UI（4 Tab / 命令面板）、互动式首启引导、PDF 导入 + 题目配图、流式 AI、许可证改 AGPL-3.0 |
| 1.28.1 | 2026-09-12 | 无 API Key 时显示示例解析、新生引导卡 |
| 1.28.0 | 2026-09-11 | 设计令牌化与 6 套配色、AI 回答篇幅三档、年度贡献图与趋势图 |
| 1.26.6.24 | 2026-06-24 | 练习 / 背题模式、五套主题、滑动切题、API Key 加密存储 |
| 1.0 | 2026-06-14 | 首个版本：DOCX 题库导入、AI 解析与追问、错题本 |

各版本的完整明细见 `git log -- CHANGELOG.md` 与对应的 GitHub Release。

