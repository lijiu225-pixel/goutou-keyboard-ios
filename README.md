# 狗头军师输入法 · iOS 键盘扩展（第一阶段）

基于 [tiantianlaolao/ios-cicd-no-mac](https://github.com/tiantianlaolao/ios-cicd-no-mac) 的 example 工程改造的**最小可运行 iOS 键盘扩展**：Windows 上写代码 → push GitHub → Actions 的 macOS runner 云端编译签名 → 出可安装 IPA。全程不碰 Mac。

## 第一阶段只做四件事

1. iPhone 能装上
2. 设置里能添加这个第三方键盘
3. 打开键盘显示 QWERTY
4. 点字母能正常输入

**明确不做**：不移植安卓代码、不做中文拼音、不接 AI、不做九键、不读剪贴板、不联网、不使用 App Group。

## 工程结构

```
project.yml                          XcodeGen 工程描述（仓库里不放 .xcodeproj）
App/                                 宿主 App：启用向导 + 自测输入框
  GoutouInputApp.swift
  ContentView.swift
  Info.plist
Keyboard/                            键盘扩展：UIInputViewController + Auto Layout
  KeyboardViewController.swift       三行字母 + 空格/删除/换行/地球
  Info.plist                         NSExtension: com.apple.keyboard-service
.github/workflows/build-ios.yml      无 Mac 构建流水线
```

两个 target：`GoutouInput`（App）和 `GoutouKeyboard`（app-extension，被嵌进 App 的 `PlugIns/`）。扩展只依赖 UIKit，纯系统控件，没有 WebView、没有第三方库，内存曲线是平的。

## 构建产物有两种

流水线一条，产物两种，取决于 Secrets 配了没有：

| 产物 | 需要什么 | 怎么装 |
|---|---|---|
| **未签名 IPA**（push main 就出） | 什么都不需要 | Windows 上用 Sideloadly/AltStore 侧载（要 iTunes + 一个 Apple ID，免费账号 7 天有效） |
| **已签名 ad-hoc IPA + 装机页**（打 `adhoc-v*` tag） | Apple 开发者账号 + 4 项签名资产 | iPhone Safari 打开安装页点一下装 |

## 跑起来

### 1. 只需要编译验证（不用 Apple 账号）

```bash
git clone https://github.com/<you>/goutou-keyboard-ios.git
cd goutou-keyboard-ios
git commit --allow-empty -m "chore: trigger" && git push
```

Actions 跑约 5-8 分钟，`GoutouInput-unsigned` artifact 里就是 IPA。

### 2. 出可 OTA 直装的包（要 Apple 开发者账号）

按 [ios-cicd-no-mac 的 01 篇](https://github.com/tiantianlaolao/ios-cicd-no-mac/blob/main/docs/01-signing-assets.md) 准备资产，配到本仓 Secrets：

| Secret | 内容 |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Apple Distribution 证书 p12（`-legacy` 打的） |
| `APPLE_CERTIFICATE_PASSWORD` | 上面 p12 的密码 |
| `APPLE_DEV_CERTIFICATE_BASE64` | Apple Development 证书 p12 |
| `APPLE_DEV_CERTIFICATE_PASSWORD` | 上面 p12 的密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_API_KEY_BASE64` | App Store Connect API Key |
| `APPLE_ADHOC_PROFILE_BASE64` | **App** 的 Ad Hoc 描述文件 |
| `APPLE_ADHOC_EXT_PROFILE_BASE64` | **键盘扩展** 的 Ad Hoc 描述文件 |
| `OTA_SSH_HOST` / `OTA_SSH_USER` / `OTA_SSH_PASSWORD` | 可选，自建 OTA 服务器才要 |

> 苹果后台要注册 **两个 App ID**：`com.example.goutouinput` 和 `com.example.goutouinput.keyboard`（扩展的 ID 必须以 App 的 ID 开头），两个都要各建一份 Ad Hoc Profile、各带测试机 UDID。改成你自己的 Bundle ID 时，`project.yml` 和 workflow 头部的 `BUNDLE_ID` / `EXTENSION_BUNDLE_ID` 要一起改。

然后：

```bash
git tag adhoc-v1.0.0 && git push origin adhoc-v1.0.0
```

约 12 分钟后 Safari 打开 `install.html` → 点安装 → 设置 → 通用 → VPN 与设备管理 → 信任证书。

## 装上之后怎么用

1. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 第三方键盘 → **狗头军师**
2. 任意输入框长按 🌐 → 选「狗头军师」
3. 点字母就能输入；⌫ 删除、空格、换行都通

> 密码框系统会强制切回自带键盘，这是 iOS 的行为，不是 bug。

## 下一阶段（现在没做）

- 中文 / 九键（`NineKeyMapper` 的多击逻辑与平台无关，是最省事的移植点）
- 军师面板（WebView 不要进键盘，放宿主 App，键盘只读 App Group）
- AI 请求（需要 `RequestsOpenAccess = YES` + 用户开「允许完全访问」）

路线细节见 Android 仓库的 `docs/ios-port.md`。

## License

MIT
