# 第三方代码与许可声明（THIRD_PARTY_NOTICES）

> NatsumeQuizMaster（基于 daimao-quiz「猫卷」二次开发）· 开源合规审计产物

## ⚠️ 关于本项目自身许可的重要说明

本项目（NatsumeQuizMaster）主体代码衍生自 **daimao-quiz（AGPL-3.0，
Copyright (C) 2026 笨蛋鱼坏蛋猫）**。根据 AGPL-3.0 的强传染性 copyleft 义务
（第 5 条、第 13 条），**衍生作品必须同样以 AGPL-3.0 分发**，不能改换为 MIT
等更宽松协议——除非对上游 AGPL 代码进行彻底的「净室重写」或取得上游作者书面
再授权。

因此本仓库根目录的 `LICENSE` **保持 AGPL-3.0**，并保留上游项目的版权声明。
daimao-quiz 的完整许可文本与 NOTICE 以其上游发布为准；本项目根目录的 `LICENSE`
为 AGPL-3.0 全文。项目的「学习 / 免费」定位是使用意图说明，不改变、也不替代
AGPL-3.0 的法律效力。

---

## 一、融合/参考项目协议审计表

| 项目 | 协议类型 | 是否有明确协议 | 关键义务 |
|---|---|---|---|
| daimao-quiz-master（「猫卷」，Copyright (C) 2026 笨蛋鱼坏蛋猫） | **AGPL-3.0** | 有（LICENSE + NOTICE） | 强传染性 copyleft：衍生作品必须同样 AGPL-3.0 分发；网络交互（SaaS）也触发源码提供义务 |
| Logseq | **AGPL-3.0** | 有（LICENSE） | 与本工程同协议，**只取形格式与交互**（`[[双链]]` 写法、Graph 视图），未引入其源码；仍在本文件致谢 |
| dsh-bili-scroll-main | **MIT** | 有（LICENSE + NOTICE.md） | 保留版权声明与许可文本即可；可商用/修改/再许可 |
| fishtalk-main | **MIT** | 有（LICENSE） | 同上 |
| NoteLLM-main | **MIT** | 有（LICENSE） | 同上；本项目移植了其切块算法（已标注来源） |
| syncthing-main | **MPL-2.0** | 有（LICENSE） | **文件级** copyleft：修改过的 MPL 文件须开源；未修改文件可与更大工程组合，不受传染 |
| Coopanion（`Pal-AI-Lab/Coopanion`，Coopanion is copyright Pal AI Lab） | **AGPL-3.0-or-later**（另附 AGPL §7 Steamworks 链接附加许可） | 有（LICENSE） | 与本工程同为 AGPL 系，**只取形「角色 / 好感度 / 情绪气泡 / 事件驱动」的交互结构**，未引入其 TypeScript 代码与 `web/whale/` 贴图；**注意：其鲸鱼娘贴图明确不在 AGPL 授权范围内**（见下节） |
| Cortico（`Pal-AI-Lab/Cortico`，Coopanion 组装所用的 agent 框架） | **MIT** | 有（LICENSE） | 保留版权声明与许可文本；本项目只参考其「Core + Persona + World」分层思路，未引入源码 |

**审计结论：8 个项目均有明确协议，无「无协议 / 保留所有权利」代码需要剔除。**
本项目主体代码衍生自 daimao-quiz，整体以 AGPL-3.0 分发；其余项目以
「独立进程 / REST 调用 / 算法移植（附署名）」方式使用，未直接并入其源文件。
Logseq 仅作为 `lib/models/note.dart`、`lib/widgets/note_graph_view.dart` 的
**格式与交互参照**（双链语法、Graph 布局思路），实现为本工程自行编写的纯 Dart 代码。

### 关于 Coopanion 的鲸鱼娘形象（素材不作为开源代码使用）

Coopanion 的 `packages/cortico-world-desktop-pet/THIRD_PARTY_NOTICES.md` 写明：
`web/whale/` 的贴图由 AI 按参考图生成后拆件，角色原设为「溟月」（上善无形），
DeepSeek 女仆装二创参考 ZipZipPipe；围裙上的标志是 DeepSeek、OpenAI、Anthropic、
Google、阿里云、月之暗面、MiniMax 的**商标图形**，归各公司所有。原文结论是
「**这些贴图不在本包的 AGPL 授权范围内**……想在别处使用请自行确认原设与各家标志的权利」。

因此本工程：

1. **不复制、不打包、不修改**上述任何贴图（`assets/companion` 目录不存在，
   `test/companion_test.dart` 用断言钉住这一点）；包内
   `assets/plugins/official/companion/avatars/` 的三张助教形象是本项目自有的
   第三方授权素材（见第四节），与 Coopanion 的 `web/whale/` 无关；
2. 陪伴插件的头像由 `lib/widgets/companion/companion_avatar.dart` 以
   `CustomPainter` **现场自绘**（原创造型，不含任何厂商商标），代码随本工程
   以 AGPL-3.0 分发；
3. 「非商用 / 免费开源」**不构成授权**：AGPL 本身允许商用，素材问题的关键是
   著作权与商标权，而不是是否收费。若将来确需上游美术资源，须另行取得
   原设作者与商标权利人的许可。



---

## 二、直接依赖（pubspec.yaml）许可清单

> 以下为**尽力而为**的许可标注；权威来源是各包内自带 LICENSE 文件，
> 可用 `flutter pub deps` 核对精确版本与出处。

| 依赖 | 常见许可 | 备注 |
|---|---|---|
| provider | MIT | 状态管理 |
| sqflite / sqflite_common_ffi | BSD-2-Clause | 本地数据库 |
| path / http / http_parser / crypto / intl / timezone | BSD-3-Clause | 基础工具 |
| file_picker / archive / xml / fl_chart / shimmer / audioplayers / uuid / image | MIT | 文件、图表、音效、图像 |
| share_plus / shared_preferences / path_provider / qr / mobile_scanner / flutter_secure_storage / flutter_local_notifications | BSD-3-Clause | 平台能力 |
| pointycastle | MIT（BSD 风格） | AES 加密 |
| flutter_timezone | MIT | 时区 |
| flutter_foreground_task / pdfrx / google_mlkit_text_recognition | **Apache-2.0** | 前台服务、PDF、端上 OCR |

### Apache 2.0 组件 NOTICE 说明
`flutter_foreground_task`、`pdfrx`、`google_mlkit_text_recognition` 采用
Apache-2.0。依据 Apache-2.0 第 4(d) 条，如原组件自带 NOTICE 文件，需随分发
保留。本仓库未修改这些组件的源文件，其完整许可与 NOTICE 见各包 `pub` 缓存
（`~/.pub-cache/` 或 `flutter pub deps` 指向的路径）。

### MPL 2.0（syncthing）说明
Syncthing 为 MPL-2.0：仅对**修改过的 MPL 文件**有开源义务。本项目以独立进程/
REST 客户端方式调用（`lib/services/sync/syncthing_client.dart` 为自行实现的
HTTP 客户端，不含 syncthing 源文件），因此本仓库不产生 MPL 传染义务。

---

## 三、AI 辅助生成声明

本项目部分逻辑由 AI 辅助生成，开发者已尽合理努力进行开源协议审查与防污染重写，
并已做反向查重：核心业务逻辑使用最基础语法自行重组，未照搬任何带有特定公司
版权头（如 Copyright OpenAI / Copyright Google）的代码。如仍有雷同或侵权，
纯属巧合，请联系开发者处理（联系方式见 `SECURITY.md`）。

---

## 四、美术素材（CC 授权，不随本项目 AGPL-3.0 分发）

代码与美术素材的授权是**分开**的：本仓库 `LICENSE`（AGPL-3.0）只覆盖代码。
下列素材是第三方作者的原创作品，以 Creative Commons 系列协议授权，版权归原作者：

| 素材文件 | 用途 | 作者 | 出处 | 授权 |
|---|---|---|---|---|
| 应用图标 logo（`assets/app_logo.png`） | 应用图标、悬浮助教头像、关于页 | 六阶堂希罗 | <https://space.bilibili.com/553336367> | CC（以原作者发布处的说明为准） |
| `assets/plugins/official/companion/avatars/{rainbow,navy,amber}.png` | 小鲸助教头像 / 角色卡 | 艾玛エマ | <https://space.bilibili.com/1327387359> | CC（以原作者发布处的说明为准） |
| `assets/plugins/official/companion/masters/{rainbow,navy,amber}.ico` | 上述 PNG 的母版，**仅仓库存档、未注册进 `pubspec.yaml`**（不进包体） | 同上 | 同上 | 同上 |

义务说明：

1. 再分发这些文件时必须**保留作者署名**与上述出处链接，并遵守原作者选择的 CC 条款
   （是否允许商用、是否要求相同方式共享，以原发布处的说明为准）；
2. 它们**不属于 AGPL-3.0 的「源代码」范围**，不能被本项目的 AGPL 授权覆盖，下游也
   不能把它们当作 AGPL 素材再许可；
3. 除上表外，界面内的插画与助教默认形象由本项目以 `CustomPainter` 自绘
   （`lib/widgets/companion/companion_avatar.dart`），随代码以 AGPL-3.0 发布；
4. 若原作者对使用方式有异议，请通过 `SECURITY.md` 中的联系方式告知，本项目会立即
   移除相关素材。
