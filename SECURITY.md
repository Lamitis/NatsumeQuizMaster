# 安全政策（SECURITY）

## 报告漏洞

如果你发现安全漏洞，请**私下**联系开发者，不要在公开 Issue 中披露细节：

- GitHub Security Advisories：
  https://github.com/Lamitis/NatsumeQuizMaster/security/advisories/new

我们将在 7 个工作日内确认并尽量在下一个版本修复。

## 特别说明：防篡改校验绕过

本应用内置自研的「防伪与签名校验」（`lib/services/integrity_service.dart`，
Android 端经 `com.natsume.quiz/integrity` 通道取签名 SHA-256 比对）。
**如果你发现了该校验可被绕过的方式，请私下报告**，不要公开利用细节，以免
被用于制作盗版。

## 已知边界（非漏洞，属设计取舍）

- 防伪校验**不阻断启动**：检测不到签名或未配置专属签名时按「unknown」处理，
  仅静默限制部分高级功能（AI 出题、世界导出）。这是为兼容换包名/换证书重打包
  而刻意为之，属预期行为。
- API Key 在非 Android 平台为混淆级存储，不承诺防专业逆向；请勿在共享设备上
  保存真实 Key。

## 报告格式

请尽量包含：受影响版本、复现步骤、影响范围、可能的修复建议。
