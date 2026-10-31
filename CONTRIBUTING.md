# 贡献指南

感谢你对NatsumeQuizMaster的关注！在提交贡献之前，请先阅读以下约定。

## 报告问题

- 使用仓库的 **Issues** 报告 Bug 或提出建议
- 报告前请先搜索是否已有相同问题
- Bug 报告请附上：平台（Android / Windows）、版本号、复现步骤、期望行为与实际行为
- **安全漏洞请勿公开提交**，见 [SECURITY.md](SECURITY.md)

## 提交代码

> **开发环境**：Flutter **3.47.8** / Dart 3.13.7（仓库 `.fvmrc` 已锁定）。首次从源码启动
> Windows 端的完整步骤（Visual Studio + ATL、插件补丁脚本、pdfium 预编译包、`flutter run -d windows`）
> 见 [README · 从源码启动](README.md#从源码启动本地开发)。

1. Fork 本仓库并基于 `main` 创建分支：
   - `feat/xxx` — 新功能
   - `fix/xxx` — 修复
   - `docs/xxx` — 文档
   - `chore/xxx` — 构建 / 杂项
2. 提交信息建议使用语义化前缀：
   - `feat: 新增 xxx`
   - `fix: 修复 xxx`
   - `docs: 更新 xxx`
   - `chore: 调整构建脚本`
3. 提交前请确保本地全部通过：
   ```bash
   flutter analyze --no-fatal-infos   # 应输出 0 error / 0 warning（info 级提示不计）
   flutter test      # 全量测试通过
   ```
   Windows 上可以直接 `powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1`：
   它会用一次性隔离的 `LOCALAPPDATA` 跑 analyze + test，避免旧测试库残留导致假红
   （开头还会自动跑 `dart tools\patch_pub_cache.dart`，补上 pdfrx 1.3.5 漏掉的空安全 `!`）。
4. 发起 Pull Request，描述清楚「改了什么、为什么改、怎么验证」

> 推送后 GitHub Actions 会自动再跑一遍 `analyze` + `test`，见 PR 上的 CI 状态。

## 开发约定

- 代码风格以 `analysis_options.yaml` 为准
- 新增功能请补充对应测试；修复类提交建议补充回归测试
- 数据库 schema 变更需提供迁移逻辑，并确保覆盖安装不丢数据
- **版本号只改一处**：`pubspec.yaml` 的 `version:` 字段。
  应用内展示的版本号由构建时 `--dart-define=APP_VERSION`（主版本，如 `v1.35.5`）
  与 `--dart-define=APP_BUILD`（构建号，如 `33`）注入，README 徽章是动态的——
  不需要（也不应该）在任何其他文件里手工改版本号。
  两个常量 `kAppVersion` / `kAppBuildNumber` 与 pubspec 不一致时
  `test/version_single_source_test.dart` 会直接报错
- **「开发者选项」的密码不写进代码**：只存 SHA-256 哈希，且由编译期
  `--dart-define=DEV_PW_HASH=<哈希>` 注入（不传则用 `developer_options_screen.dart`
  里的默认值，正式包行为不变）。生成哈希的 PowerShell 一行命令与用法见
  [docs/开发者选项.md](docs/开发者选项.md)
- **签名文件与密钥永不入库**：`android/key.properties`、`**/*.jks`、`**/*.keystore`
  已在 `.gitignore` 排除，请勿私自加回

## 许可

向本项目提交贡献即表示你同意你的贡献以本项目的 [AGPL-3.0](LICENSE) 许可协议发布。

简单说：你可以自由使用、修改、分发（包括商业用途），但**修改后的衍生作品必须
同样以 AGPL-3.0 开源**；若把修改版作为网络服务提供，须向使用者提供完整源码。
