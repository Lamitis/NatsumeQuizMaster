<div align="center">

# NatsumeQuizMaster

**本地优先的 AI 备考刷题工具**

题库自建 · 数据自管 · AI 讲解 · 算法复习

[![平台](https://img.shields.io/badge/平台-Android%20%7C%20Windows-2563EB?style=flat-square)](#下载安装)
[![版本](https://img.shields.io/github/v/release/Lamitis/NatsumeQuizMaster?style=flat-square&label=版本&color=2F7D5B)](https://github.com/Lamitis/NatsumeQuizMaster/releases)
[![许可](https://img.shields.io/badge/许可-AGPL--3.0-2DA8A6?style=flat-square)](LICENSE)
[![CI](https://github.com/Lamitis/NatsumeQuizMaster/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Lamitis/NatsumeQuizMaster/actions/workflows/ci.yml)

</div>

---

NatsumeQuizMaster 是一个面向备考场景的本地刷题工具，目标是把学习数据的所有权交给使用者：

- **题库自建** —— 导入题库文档，自动转换为可练习的题库
- **数据自管** —— 题库、错题、批注、复习进度全部保存在本机，离线可用，可随时备份迁移
- **AI 讲解** —— 按「题眼破题法」逐题讲解并支持追问，使用自己的 API Key 直连服务商
- **算法复习** —— 内置 FSRS-5 间隔重复算法，按遗忘曲线安排错题复习

**无账号 · 无广告 · 无会员 · 基础功能完全免费。**

> **开源生态二次开发声明**：本项目主体代码衍生自 **daimao-quiz「猫卷」**
> （AGPL-3.0，Copyright (C) 2026 笨蛋鱼坏蛋猫），并融合 NoteLLM / Syncthing 等思路。
> 根据 AGPL-3.0，衍生作品同样以 AGPL-3.0 分发。上游与第三方许可、署名见
> [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，隐私说明见
> [PRIVACY.md](PRIVACY.md)，免责声明见 [DISCLAIMER.md](DISCLAIMER.md)。

---

## 功能特性

### 上手引导

新装首次启动会展示 **13 步互动式引导**：每一步高亮对应的真实控件，并跟随用户进入二级页面
（导入页 / 错题本 / 设置中心 /「开始刷题」弹窗），最后一步完成一次真实的导入与刷题流程。
点击高亮处即可继续，随时可以跳过；「我的 → 重看使用引导」可重播。

### 智能建库

| 功能 | 说明 |
|------|------|
| DOCX / PDF 导入 | 长文档按题目边界切块，多路并发解析，不阻塞界面；PDF 本地抽取图文，插图随题保留；无文字层的扫描件走端上离线 OCR（ML Kit 中文，不联网、不占用 API 额度） |
| 题目配图 | 图片随位置在题干 / 选项 / 解析中内联显示，备份、同步、导出随题保留 |
| JSON 导入 | 结构化题库直接入库，无需 AI 解析 |
| 可视化校对 | 入库前逐题预览、编辑、删除，并显示 AI 生成的知识点标签 |
| 一键导出 | 题库导出为标准 JSON，可分享给其他使用者直接导入 |
| 多库管理 | 多题库并存，可单独或组合练习；重名自动编号 |

### AI 讲解

| 功能 | 说明 |
|------|------|
| 题眼破题法 | 四步拆解：抓题眼 → 理逻辑 → 指坑点 → 划重点 |
| 篇幅三档 | 简洁（≤150 字）/ 标准（≤300 字）/ 详细，设置中可切换 |
| 关键词高亮 | 答案绿、题眼蓝、避坑红；标出关键依据与易错否定词 |
| AI 追问 | 独立全屏对话页，问答按题保存；右上角「知识库引用」可随时开关 |
| 知识库接地 | 解析与追问会先检索已导入的知识库：资料覆盖的部分优先并标注「依据你导入的资料」，资料没覆盖的部分仍由 AI 自身知识补全（知识库不一定全面）；未建库 / 无命中时与普通解析完全一致 |
| 接口兼容 | 兼容任意 OpenAI 兼容接口（官方 API 与第三方订阅均可） |
| 连接测试 | 设置页可测试 API 可用性，并拉取可用模型列表 |

### 刷题

| 功能 | 说明 |
|------|------|
| 三种模式 | 正常刷题（答完即判）/ 练习（限时或不限时 + 答题卡）/ 背题（高亮答案、不计统计） |
| 自由选题 | 首页「自由选题」一次确认：题库范围（可多选）→ 知识点 → 题型 → 题量 → 模式，不必先回题库管理勾选（原「定向爆破」） |
| 题号网格 | 题库管理里点题库，默认是一屏日历式题号方块：点第几号就从第几题开始刷（练习 / 背题同效），可随时切回列表视图做编辑 |
| 双链笔记 | 解析卡「写笔记」随手记，`[[双链]]` / `#标签` / 反向链接 / Graph 图谱，按题库分组（插件数据仅本机，**不参与同步**） |
| 小鲸助教 | 内置陪伴 bot：按连胜 / 今日题量 / 本周正确率 / 错题到期打气与给建议，自绘鲸鱼娘头像随情绪变表情，快捷问句 + 好感度；未配 API Key 也能用固定话术。**应用内悬浮**（可拖动；点一下 = 戳它一下就地回话；右键 / 长按出「聊天 / 设置 / 今天先别出现」，聊天是悬浮气泡输入框，不跳页），可在助教设置里改角色名、语气与人设，单独配模型接口，打开知识库引用与对话记忆（数据仅本机，**不参与同步**） |
| 七种题型 | 单选、多选、判断、填空、名解、简答、问答，各有对应判分逻辑 |
| 断点续刷 | 中途退出保留进度，下次从首页继续 |
| 滑动切题 | 左右滑动切换上一题 / 下一题 |
| 手动改判 | 主观题可修正判定结果，不新增记录、不影响统计 |
| 答题音效 | 对错提示音，可在设置中开关 |

### 错题与复习

| 功能 | 说明 |
|------|------|
| FSRS-5 排期 | 按遗忘曲线计算每道错题的下次复习时间，只显示到期题目 |
| 行为自动评分 | 答错 / 快速答对 / 缓慢答对映射为不同记忆难度，无需手动打分 |
| 薄弱诊断 | 按题库、按知识点统计正确率，定位薄弱环节（本地统计无需 Key；AI 深度诊断需 Key） |
| 知识点标签云 | 按知识点聚合错误，可一键专项复习 |

### 手写批注

| 功能 | 说明 |
|------|------|
| 直接手写 | 在题目上圈关键词、划重点、写推导 |
| 三种笔型 | 细笔 / 普通笔 / 荧光笔，支持压感调宽 |
| 按题保存 | 笔迹按题目持久化，切题、重启、换设备均不丢失 |
| 跨设备隔离 | 批注按设备各存一份，多端同步时互不覆盖 |

### 数据可视化

| 功能 | 说明 |
|------|------|
| 年度坚持 | 年度热力图，一整年 53 周可一屏查看 |
| 近一年趋势 | 双 Y 轴对照（题量柱状 + 平滑正确率曲线），支持分页与单日明细 |
| 正确率排行 | 按题库 / 按知识点两个维度统计 |
| 错题统计 | 总数、待复习、按题库分布、最早到期时间 |
| 历史会话 | 每轮练习可回看，支持改判修正 |

### 多端与同步

| 功能 | 说明 |
|------|------|
| 局域网同步 | 同一 Wi-Fi 下自动发现设备，双向交换题库与刷题进度，不经过云端 |
| 识别码校验 | 同步前需配对：设备长码（可复制、可出二维码）或 6 位临时码（10 分钟有效、可随时作废）。未配对时不发起任何请求 |
| 扫码配对 | 扫描配对二维码即可连接；连接成功后发起同步 |
| 只同步题库 | 可只交换题库、题目与配图（不含刷题记录），便于分享自制题库 |
| 同名题库比对 | 按题目内容指纹比对：完全一致则跳过；不一致时由用户选择「增添（仅合并对方多出的题目）」或「覆盖」 |
| 三端自适应 | 手机底部导航，宽屏（平板 / 桌面）切换为左侧导航与左右并排布局 |
| 深色模式 | 三套主题各含深色变体，可跟随系统或手动切换 |
| 每日提醒 | 本地时区排程 + 前台服务保活，按时提醒刷题 |
| 寒暑假模式 | 假期暂停提醒与复习排期，不中断连续打卡 |

### 本地知识库 / 本地模型 / 插件（v13 新增）

| 功能 | 说明 |
|------|------|
| 知识库 | 导入课件、笔记、教材（txt/md/docx/pdf），本地切块检索；AI 出题只依据库内资料，资料未覆盖时明确说明（降低幻觉） |
| 知识库导出导入 | 知识库可整体导出为 `.json` 分享并再次导入；导入后可改名、编辑、删除文档 |
| 自动分学科 | 优先通过 HTTP 调用通义等极速模型，断网时回退到本地关键词分类（无原生构建） |
| 多种 AI 接口 | 支持 OpenAI 兼容（DeepSeek / 通义 / 智谱 / Kimi 等）/ Anthropic / Gemini / Ollama |
| 自动出题 | 选择知识库 → AI 工具调用检索资料 → 将题目写入沙箱 JSON → 一键导入题库 |
| 世界总览 + 插件 | 「世界」是知识库 + 题库 + 插件的打包单元；插件为声明式包（清单 + 提示词 + 资产），可自行制作分发；内置插件两个：双链笔记（`natsume.notes`）、小鲸助教（`natsume.companion`），均标注「无法同步」 |
| Syncthing 同步 | 参考 Syncthing 实现手机与电脑跨网络同步，扫码配对即可使用 |

> 插件开发见 [docs/插件开发指南.md](docs/插件开发指南.md)；签名与分发见
> [docs/签名与分发.md](docs/签名与分发.md)；同步说明见
> [docs/同步说明.md](docs/同步说明.md)。

---

## 下载安装

项目主页：[https://github.com/Lamitis/NatsumeQuizMaster](https://github.com/Lamitis/NatsumeQuizMaster)

前往 **[Releases](https://github.com/Lamitis/NatsumeQuizMaster/releases/latest)** 下载最新版本。

| 平台 | 文件 | 说明 |
|------|------|------|
| Android | `Natsume-v<版本>-android-arm64.apk` | 2017 年后绝大多数手机，约 20 MB |
| Android | `Natsume-v<版本>-android-universal.apk` | 含全部 CPU 架构，不确定机型时使用，约 35 MB |
| Windows | `Natsume-v<版本>-windows-setup.exe` | Windows 10/11 64 位安装包 |
| Windows | `Natsume-v<版本>-windows-portable.zip` | 免安装版，解压即用 |

> 文件名中的 `<版本>` 随版本变化（例如 `Natsume-v1.29.0-android-arm64.apk`），
> 请以 Releases 页面上的实际文件名为准。
> 每个 Release 均附 `SHA256SUMS.txt` 校验值，下载后可自行核对完整性
> （校验方法见下方[安装与校验](#安装与校验)）。

> **基础刷题功能完全离线可用**，无需联网或配置任何内容。
> 需要 API Key 的只有三类：**DOCX/PDF 题库导入**（题目由 AI 解析）、AI 逐题讲解与追问、
> 错题本的「生成建议」（AI 深度诊断）。
> **JSON 题库文件与内置示例题库均不需要 Key，也无需联网。**

### 关于 API Key

NatsumeQuizMaster 采用 **BYOK（Bring Your Own Key）** 模式：AI 请求由用户自己的 Key 直连模型服务商，
项目方不接触用户数据，也不承担 API 成本。

1. 到模型服务商申请 API Key（默认适配 DeepSeek，也兼容通义、智谱、Kimi、OpenAI、OpenRouter 等）
2. 打开 NatsumeQuizMaster → 设置 → 填入 Key 与接口地址（预设列表可一键填入）
3. 点「测试连接」确认可用，再点「选择模型」拉取可用模型

---

## 安装与校验

### 关于系统安全提示

安装包目前**未购买代码签名证书**，因此两个平台首次安装时都可能给出提示。
这是「未签名」而非「有问题」，按以下步骤正常安装即可：

| 平台 | 出现的提示 | 处理方式 |
|---|---|---|
| Windows | SmartScreen「Windows 已保护你的电脑」 | 点「**更多信息**」→「**仍要运行**」 |
| Android | 「未知来源」/「禁止安装未知应用」 | 在系统设置中为当前文件管理器开启「允许安装未知应用」，或在安装提示中直接选择「允许」 |

> 如不放心，请继续阅读下方校验步骤——**核对 SHA-256 后再安装**是最稳妥的做法。
> 请只从本仓库 Releases 下载，不要使用第三方转载的安装包。

### 校验 SHA-256

每个 Release 都附有 `SHA256SUMS.txt`，包含四个产物的完整校验值。

**Windows（PowerShell）**

```powershell
# 将文件名替换为实际下载的文件
Get-FileHash .\Natsume-v1.29.0-windows-setup.exe -Algorithm SHA256
```

将输出的 `Hash` 与 `SHA256SUMS.txt` 中对应行对比，一致即表示文件完整、未被篡改。

**Android**：使用任意哈希校验工具计算 APK 的 SHA-256，
与 `SHA256SUMS.txt` 中 `-android-arm64.apk` 那一行对比。

---

## 快速上手

1. 安装并打开 NatsumeQuizMaster
2. 首页 →「导入题库」→ 选择文件：
   - **`.json` 题库** —— 直接入库，**无需 Key**
   - **`.docx` / `.pdf` 文档** —— 由 AI 解析题目，**需要先在设置中配置 Key**（未配置时导入页会提示）；PDF 插图会随题保留并显示
   - 也可以直接点「一键导入示例题库」离线体验（无需文件、无需 Key）
3. 首页勾选题库 →「自由选题」→ 选择题量与模式 → 开始刷题
4. 答完查看解析：题目自带解析**无需 Key**；配置 Key 后可查看 AI 逐题讲解，并可「向 AI 追问」
5. 答错的题自动进入错题本，FSRS 按遗忘曲线安排复习

---

## 数据与隐私

| 项 | 说明 |
|----|------|
| 数据存储 | 全部数据保存在设备本地 SQLite 数据库，离线可用，卸载即彻底删除 |
| 备份迁移 | 一键导出数据库，换设备导入即可恢复题库、记录与批注。**默认不含 API Key**（换机后重新填写）；如需连同 Key 迁移，可设置备份口令，整个备份文件将被加密 |
| API Key 加密 | AES-256-GCM 加密，Android 上优先存入系统 Keystore |
| 无账号体系 | 不采集个人信息，无登录、无云端上传 |
| 防篡改 | 签名校验，二次打包后拒绝启动 |
| 发布构建 | 开启代码混淆，防止反编译读取 |

---

## 工程质量

- **完整的自动化测试套件**，覆盖判题、复习算法、数据层、导入解析（含 PDF 图文抽取与配图归属）、同步、布局自适应等
  （每次 push 由 [GitHub Actions](https://github.com/Lamitis/NatsumeQuizMaster/actions) 自动执行，见上方 CI 徽章）
- 数据库 schema v15，外键级联、索引优化、事务一致性（v15＝题库分类树，v12＝题目配图）
- 每次发版依次执行：静态分析（0 error / 0 warning）→ 全量测试 → 混淆构建 → **组件 / 权限 / 文案 / 资源四维基线对照校验** → 签名校验

发布历程：2026 年 6 月 15 日立项 → 8 月完成 42 项修复与 AES 加密 →
8 月起重建为 NatsumeQuizMaster，完成全新 UI、手写批注、三端适配与 AI 能力扩展；
10 月 v1.29.0 补齐题库分享（识别码 + 扫码配对 + 同名题库比对）与 13 步上手引导。

---

## 技术栈

Flutter 3.47.8 · Dart 3.13.7 · SQLite (sqflite) · Provider · FSRS-5 · AES-256-GCM · UDP 局域网发现

---

## 从源码启动（本地开发）

下面以 **Windows 桌面端** 为主线，每一步都在本机（Windows 11 + Flutter 3.47.8 + VS 2026 Build Tools）实机跑通过；
Android 见第 6 步末尾。

### 1. 环境要求

| 组件 | 要求 | 本项目验证环境 |
|---|---|---|
| Flutter SDK | 标准版本 **3.47.8**（Dart 3.13.7），仓库 `.fvmrc` 已锁定 | Flutter 3.47.8 stable |
| Visual Studio | 「使用 C++ 的桌面开发」工作负载 + **ATL** 组件 + Windows 10/11 SDK ≥ 10.0.17763 | VS 2026 Build Tools 18.10 / MSVC 14.51.36231 / SDK 10.0.26100.0 |
| Windows | 设置 → 系统 → 开发者选项 → **开发人员模式 = 开**（插件目录用符号链接） | Windows 11 |
| JDK 17 + Android SDK | 只在需要跑 Android 端时准备 | JDK 17 |

没装 Visual Studio 时可用仓库脚本一键装（管理员 PowerShell，10~30 分钟）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\install_vs_buildtools.ps1
```

用 FVM 固定版本时，把下面所有 `flutter` 替换成 `fvm flutter`：

```powershell
fvm install && fvm use      # .fvmrc = 3.47.8
```

### 2. 获取源码

```powershell
git clone https://github.com/Lamitis/NatsumeQuizMaster.git
cd NatsumeQuizMaster
```

也可以直接在 GitHub 页面选「Download ZIP」解压，效果相同。**不要**用 `dist\` 里的发布产物代替源码。

### 3. 校验工具链

```powershell
flutter --version     # 期望输出 Flutter 3.47.8 / Dart 3.13.7
flutter doctor -v     # "Visual Studio - develop Windows apps" 一项必须是 ✓
```

### 4. 拉取依赖

```powershell
flutter pub get
```

依赖版本由 `pubspec.lock` 锁定（其中 `pdfrx` 固定 **1.3.5**）。请勿随手 `flutter pub upgrade` 后提交新的 lock：
pdfrx 2.x 是破坏性 API 变更（`PdfViewer` 等参数整体重写），1.0.x 的空安全更不完整；
而 **1.3.5 自身也漏了两处 `!`**，由下一步的 `tools/patch_pub_cache.dart` 补齐。

### 5. 给 pub 缓存里的插件打补丁（必做）

新版 MSVC 会拒绝三个插件的 Windows 端源码（`share_plus` 的旧 C++/WinRT 头、
`flutter_secure_storage_windows` 的类名限定、`flutter_local_notifications_windows`
的 `CW2A` 隐式转换）。这些源码在 pub 缓存里，装依赖时会被还原，所以用幂等脚本就地修：

```powershell
powershell -ExecutionPolicy Bypass -File tools\patch_windows_plugin_deps.ps1
# 只检查是否已就绪、不写文件：加 -WhatIfOnly
```

- 输出里没有 `[未匹配]` / `[缺失]`，退出码为 0 → 已就绪。
- 何时需要重跑：首次克隆后、`flutter pub cache repair`、升级/重装这三个插件之后。
- 原因与逐条改动见 [docs/Windows构建说明.md](docs/Windows构建说明.md) 第 6 节。

此外还有一处**与平台无关**的补丁（本地、CI、Android / Windows 构建都要），打的是
`pdfrx 1.3.5` 自己漏掉的两个 `!`：

```powershell
dart tools\patch_pub_cache.dart
# 只检查是否已就绪、不写文件：加 --check
```

- 补的位置是 `pdfrx-1.3.5/lib/src/pdfium/pdf_file_cache.dart` 的 351 / 353 行
  （`PdfFileCache?` 类型的参数在闭包内不享受类型提升）。不补的话，**任何干净环境**
  （新克隆、CI、`flutter pub cache repair` 之后）编译 pdfrx 必然失败，报
  `Property 'blockSize' cannot be accessed on 'PdfFileCache?'...`；
  在 CI 侧它还会伪装成「一批测试套件 `loading … [E]`」，看起来像测试基础设施坏了。
- 何时需要重跑：与上面几个插件相同（每次 `flutter pub get` 重新解包依赖之后）。
  CI 的分析 / 测试 / 构建任务与 `tools\run_tests.ps1` 都会自动先跑一遍。
- 为什么不直接升级 pdfrx：2.0.0 起 API 破坏性变更（整套 `PdfViewer` 参数重写），
  1.3.5 之后没有 1.3.6 / 1.4.x 这类只修 bug 的版本。细节见脚本头部注释。

### 6. 启动（开发模式，支持热重载）

```powershell
flutter devices            # 确认能看到 "Windows (desktop)"
flutter run -d windows     # 启动；终端里 r=热重载  R=热重启  q=退出
```

> 本机实测：`flutter run -d windows` 首次编译 38.9s，随后出现
> `Built build\windows\x64\runner\Debug\natsume_quiz_master.exe`、
> `Syncing files to device Windows` 与 `Flutter run key commands.`，
> 说明调试服务已连上（此时按 `r` 即可热重载）。

首次运行会自动触发 CMake 配置 + 编译（约 1~3 分钟）。如果配置阶段报
`file COPY cannot find ".../pdfium.dll"`，说明 CMake 没能下载 pdfium 预编译包，
手动补一次即可：

```powershell
$ver = 'chromium%2F7202'                      # 对应 pdfrx 1.3.5 的 PDFIUM_RELEASE
$dir = "build\windows\x64\pdfium\$ver"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
curl.exe -L -o "$dir\pdfium-win-x64.tgz" `
  "https://github.com/bblanchon/pdfium-binaries/releases/download/$ver/pdfium-win-x64.tgz"
tar.exe -xzf "$dir\pdfium-win-x64.tgz" -C $dir   # 解压出 bin/pdfium.dll、include/、lib/
flutter run -d windows
```

`flutter clean` 或删掉 `build\` 之后需要重做这一步。

不想用 `flutter run` 时，构建后直接双击 exe 也能启动：

```powershell
flutter build windows --debug
.\build\windows\x64\runner\Debug\natsume_quiz_master.exe
```

**Android 端**（同一套源码，需先装 JDK 17 + Android SDK）：

```powershell
flutter devices             # 应出现真机（USB 调试）或模拟器
flutter run -d <device-id>
```

### 7. 本地数据与重置

应用数据保存在 `%LOCALAPPDATA%\natsume_quiz_master\flashcard.db`（SQLite，含题库、
刷题记录、批注）。想从全新状态启动：关闭应用后删掉整个
`%LOCALAPPDATA%\natsume_quiz_master` 目录（这是整库重置，不是删除某个题库）。

### 8. 启动 / 编译失败对照表

| 现象 | 原因与处理 |
|---|---|
| `error C1083: Cannot open include file: 'atlbase.h'` | VS Installer 里补勾 **ATL** 组件 |
| `error C2338: static assertion failed`（`<experimental/coroutine>`） | `windows/CMakeLists.txt` 的全局 `set(CMAKE_CXX_STANDARD 20)` 被改掉了，恢复即可 |
| `vector.h: error C2065: 'ElementType'` 等上百条连锁错误 | 没执行第 5 步的补丁脚本 |
| `CMake Error ... file COPY cannot find "...pdfium.dll"` | 按第 6 步手动下载 pdfium |
| `Could not find any instance of Visual Studio` | 缺「使用 C++ 的桌面开发」工作负载，跑 `tools\install_vs_buildtools.ps1` |
| `Building with plugins requires symlink support` | 未开启 Windows「开发人员模式」 |
| 启动即闪退且无界面 | 用终端跑 exe 看 stderr；多半是缺 `pdfium.dll` 或 VC++ 运行库 |

## 从源码构建

> 命令行构建 / 打包 / 提交前门禁如下；Windows 端环境细节与逐条故障排查见
> [docs/Windows构建说明.md](docs/Windows构建说明.md)。

```bash
flutter pub get
flutter analyze --no-fatal-infos   # 应输出 0 error / 0 warning（info 级提示不计）
flutter test                    # 全量测试
flutter build apk --release --obfuscate --split-debug-info=build/symbols
flutter build windows --release
```

**Windows 打包**（一条命令出「绿色版 + zip + 安装包」）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1
# 产物：
#   dist\NatsumeQuizMaster-Windows-<yyyyMMdd>\           绿色版目录（免安装）
#   dist\NatsumeQuizMaster-Windows-<yyyyMMdd>.zip        绿色版压缩包
#   dist\NatsumeQuizMaster-Setup-<版本>-Windows-x64.exe  安装包
#   dist\make_setup.log                                  全过程日志
```

常用开关：

```powershell
# 只复用已有 build 产物，不重新构建
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1 -SkipBuild

# 只出免安装版（不需要 Inno Setup）
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1 -PortableOnly

# 本机没装 Inno Setup 6 时自动装（先试 winget；再下 GitHub release 的官方安装包，
# 用 /CURRENTUSER 装到 %LOCALAPPDATA%\Programs\Inno Setup 6 —— 不需要管理员权限）
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1 -InstallInnoSetup

# Inno Setup 装在自定义目录（如 D:\Tools\Inno Setup 6）时，直接指定 ISCC 位置
# （也可以 setx ISCC "D:\Tools\Inno Setup 6\ISCC.exe" 设一次环境变量）
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1 -IsccPath "D:\Tools\Inno Setup 6\ISCC.exe"
```

版本号与 `--dart-define` 由脚本从 `pubspec.yaml` 自动推导（与 CI 一致）；
也可以手动分三步来做：

```powershell
flutter build windows --release --dart-define=APP_VERSION=v1.35.0.28
powershell -ExecutionPolicy Bypass -File tools\package_windows.ps1
# 产物：dist\NatsumeQuizMaster-Windows-<yyyyMMdd>\（绿色版目录）+ 同名 .zip

# 可选：生成安装包（需 Inno Setup 6；与 CI 用法一致）
# ISCC.exe 常见位置有两个：全局安装（Program Files (x86)）或仅当前用户安装
$V = '1.35.0'
$pkg = "$PWD\dist\NatsumeQuizMaster-Windows-$(Get-Date -Format yyyyMMdd)"
$iscc = @(
  'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
& $iscc "/DMyAppVersion=$V" "/DSrcDir=$pkg" "/DOutDir=$PWD\dist" "$PWD\tools\natsume_setup.iss"
```

> 绿色版目录里必须同时有 `natsume_quiz_master.exe`、`flutter_windows.dll`、`pdfium.dll` 和 `data\`；
> 目标机器还需要 **Microsoft Visual C++ 2015-2022 Redistributable (x64)**
> （`package_windows.ps1` 生成的 `使用说明.txt` 已提示）。

> Windows 上推荐使用完整门禁脚本：
> `powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1`
> 它会为本次运行分配一次性的 `LOCALAPPDATA`（测试库目录）并在结束后清理。
> 直接运行 `flutter test` 时，若 `%LOCALAPPDATA%\natsume_quiz_master` 中留有旧 schema
> 的测试库，可能因 `onCreate` 不再触发而出现 `no such table: main.question_images`
> 等大量误报（清掉该目录即可恢复）。

> 版本号的唯一来源是 `pubspec.yaml` 的 `version:` 字段（形如 `1.29.0+21`）。
> 发布构建通过 `--dart-define=APP_VERSION=v<版本名>.<构建号>` 将其注入应用内展示，
> 无需在任何 Dart 文件中手工修改版本号。
> `test/version_single_source_test.dart` 会校验两者一致，防止版本号漂移。
>
> 本地开发直接 `flutter run` 时，应用内显示的是 `kAppVersion` 的默认值（不带
> `--dart-define`），与正式包的展示一致即可，无需特殊处理。

> ⚠️ **签名文件与密钥永不入库**：`android/key.properties`、`**/*.jks`、`**/*.keystore`
> 均已在 `.gitignore` 中排除。请自行生成签名并妥善离线备份。

---

## 常见问题

**Q：必须配置 API Key 才能使用吗？**
不需要。刷题、判分、错题本、复习排期、手写批注、数据统计全部离线可用；
**JSON 题库与内置示例题库也不需要 Key、无需联网**。

需要 Key 的只有三类：

1. **DOCX/PDF 题库导入** —— 题目由 AI 解析，没有 Key 无法导入（导入页会直接提示去配置）；
2. **AI 逐题讲解与「向 AI 追问」**；
3. **错题本的「生成建议」**（AI 深度诊断）。

本地错题统计、知识点标签、正确率排行都不需要 Key。

**Q：数据会被上传吗？**
不会。所有数据保存在本机数据库；AI 请求由用户自己的 Key 直接发往模型服务商，不经过本项目。

**Q：AI 回答太长或太短怎么办？**
设置 →「AI 回答风格」→ 回答详细程度可选简洁 / 标准 / 详细，并可开关关键词高亮。

**Q：如何备份到新手机？**
设置 → 导出数据库备份 → 在新机导入即可恢复题库、记录与批注。

默认导出的备份**不含 API Key**（避免把备份发给他人时一并泄露 Key），
换机后重新填写一次即可。如需连同 Key 迁移，导出时选择「含 API Key」并设置备份口令，
整个备份文件将使用该口令加密（AES-256-GCM），导入时需要输入同一口令。
**口令丢失则备份无法恢复**，请妥善保管。

**Q：支持哪些题型？**
单选、多选、判断、填空、名词解释、简答、问答，共七种。

---

## Roadmap

| 方向 | 状态 | 说明 |
|---|---|---|
| iOS 版本 | 评估中 | 代码已具备大部分平台判断，缺少 Xcode 构建链与 iOS 侧适配（数据库路径、提醒、通知权限） |
| 题库分享 | 已实现 | v1.29.0 起支持局域网「只同步题库」+ 识别码校验 + 扫码配对 + 同名题库比对。仅限用户自制题库分享，规避第三方教辅版权风险 |
| 代码签名证书 | 评估中 | 消除 Windows SmartScreen 与 Android「未知来源」提示 |

如有优先需求，欢迎在 [Issues](https://github.com/Lamitis/NatsumeQuizMaster/issues) 中讨论。

---

## 参与贡献

- 发现 Bug 或有建议：提交 [Issue](https://github.com/Lamitis/NatsumeQuizMaster/issues)
- 修改代码：先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，从 `main` 开分支
- 安全问题：请勿公开提交，见 [SECURITY.md](SECURITY.md)

---

## Star

如果 NatsumeQuizMaster 对你有帮助，欢迎给项目一个 Star。

---

## 致谢

- 作者：夏目安安（Natsume An-An）
- 上游项目：**daimao-quiz「猫卷」**（AGPL-3.0，Copyright (C) 2026 笨蛋鱼坏蛋猫）
- 项目名与图标形象参考：夏目アンアン（Natsume An-An）
- 开发过程中使用了 AI 编程工具辅助
- 感谢所有提供反馈与建议的早期用户

## 特别鸣谢与版权说明（美术素材）

本项目的**代码**以 AGPL-3.0 分发，但**美术素材走的是原作者自己的 CC 授权**，
不属于 AGPL-3.0 覆盖范围。素材版权归原作者所有，本项目仅获得使用许可：

| 素材 | 用途 | 作者 / 出处 | 授权 |
|---|---|---|---|
| 应用图标 logo | 应用图标、悬浮助教头像 | **六阶堂希罗**（B 站主页 <https://space.bilibili.com/553336367>） | Creative Commons（以原作者发布处的说明为准） |
| 助教形象 · 彩虹发 / 蓝发 / 橙发 | 小鲸助教头像、角色卡（`assets/plugins/official/companion/avatars/`；`masters/*.ico` 母版只做仓库存档、不进包体） | **艾玛エマ**（B 站主页 <https://space.bilibili.com/1327387359>） | Creative Commons（以原作者发布处的说明为准） |

- **不属于 AGPL-3.0**：上表素材不适用本仓库 `LICENSE`；二次分发或再创作请遵守原作者
  的 CC 条款并保留署名，商用或改编前请先联系原作者。
- 除上表外的界面插图、助教默认形象均为本项目自绘（如
  `lib/widgets/companion/companion_avatar.dart`），随代码以 AGPL-3.0 发布。
- 完整清单（含第三方代码许可）见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可

[GNU AGPL-3.0](LICENSE) —— 自由使用 · 修改 · 分发，衍生作品须同样开源

- **自由使用** —— 可自由使用、修改、分发本项目，包括商业用途
- **相同方式共享** —— 修改后的衍生作品必须以同样的 AGPL-3.0 开源
- **网络服务须开源** —— 若将修改版作为网络服务提供，须向使用者提供完整源码
- **无担保** —— 按「现状」提供，不附带任何明示或暗示的担保

Copyright (c) 2026 夏目安安（Natsume An-An）

基于 daimao-quiz「猫卷」二次开发，Copyright (C) 2026 笨蛋鱼坏蛋猫

> 完整协议文本见 [LICENSE](LICENSE)。选择 AGPL-3.0 而非 MIT 等宽松协议，
> 是为了确保本项目及其任何衍生版本**始终对使用者保持开源**：
> 任何人都可以使用、修改，但不能修改后闭源。
