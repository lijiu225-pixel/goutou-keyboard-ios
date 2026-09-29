# 狗头军师输入法 · iOS 键盘扩展

基于 [tiantianlaolao/ios-cicd-no-mac](https://github.com/tiantianlaolao/ios-cicd-no-mac) 的 example 工程改造的**最小可运行 iOS 键盘扩展**：Windows 上写代码 → push GitHub → Actions 的 macOS runner 云端编译签名 → 出可安装 IPA。全程不碰 Mac。

## 已完成

**第一阶段（跑通链路）**

1. iPhone 能装上
2. 设置里能添加这个第三方键盘
3. 打开键盘显示 QWERTY
4. 点字母能正常输入

**第二阶段（中文九键移植中）**

1. 中文九键界面，布局对标 Android 稳定版（标点列 | 1-9 宫格 | ⌫/重输/0 列 + 候选条 + 底部动作行）
2. 九键多击打拼音，词库出候选，点候选上屏
3. 九键 ↔ 英文 26 键随时切换，英文 26 键功能不变

**明确不做**：不移植狗头军师 AI、Function Kit、读屏、剪贴板、联网、App Group，也不做中文大词库 / RIME。

## 工程结构

```
project.yml                          XcodeGen 工程描述（仓库里不放 .xcodeproj）
App/                                 宿主 App：启用向导 + 自测输入框
  GoutouInputApp.swift
  ContentView.swift
  Info.plist
Keyboard/                            键盘扩展：UIInputViewController + Auto Layout
  KeyboardViewController.swift       两种布局的控制器 + textDocumentProxy 上屏
  NineKeyKeyboardView.swift          中文九键界面（对标 Android 布局与配色）
  NineKeyMapper.swift                九键多击字母循环（与 Android 逐行对应）
  GoutouDictionary.swift             20 词词库（与 Android 一字不差）
  NineKeyInputEngine.swift           中文九键输入状态机（composing / flush / 回删）
  Info.plist                         NSExtension: com.apple.keyboard-service
tools/NineKeyCheck/main.swift        九键逻辑冒烟测试（CI 上 swiftc 直接跑，不需要模拟器）
.github/workflows/build-ios.yml      无 Mac 构建流水线
```

两个 target：`GoutouInput`（App）和 `GoutouKeyboard`（app-extension，被嵌进 App 的 `PlugIns/`）。扩展只依赖 UIKit，纯系统控件，没有 WebView、没有第三方库，内存曲线是平的。

### 跨平台复用的那一层

`NineKeyMapper` / `GoutouDictionary` / `NineKeyInputEngine` 只依赖 Foundation，不碰 UIKit，
是 Android 那边 `NineKeyMapper.kt` 和 `GoutouInputMethodService` 里跟平台无关的部分：

| Android | iOS |
|---|---|
| `NineKeyMapper.kt`（多击循环、650ms 窗口） | `NineKeyMapper.swift` 逐行对应 |
| `dictionary` map（20 词） | `GoutouDictionary.swift` |
| `composing` / `lastNineKey` / `flushComposing` / `deleteOnce` 的拼音部分 | `NineKeyInputEngine.swift` |
| `renderNineKeyLayout` / `renderCandidateBar` / `handleKey` | `NineKeyKeyboardView.swift` + 控制器里的 `handleNineKeyAction` |

Android 专属的 `InputMethodService`、`View` 树、JNI 一律没搬，按 Keyboard Extension 的
`UIInputViewController` + `textDocumentProxy` 重写。

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

### 中文九键怎么打

默认进中文九键。底部左边「中英」切英文 26 键，26 键底部的「中」切回九键，切换结果会被记住。

九键按**数字序列**出候选（和手机上其他九键输入法一致）：

- 按 `6` `4` `4` `2` `6` → 候选「你好」，点一下上屏
- 键盘顶部一行显示你按的数字和它命中的拼音（`64426 · nihao`），没有命中就只显示数字
- `1` 直接上屏「，」；`0` / 空格：有候选先上屏首候选，没有就打空格
- `重输` / `清空` 丢掉当前数字序列；`⌫` 先吃数字，数字空了才删正文
- `123` 切**数字页**（完整 0-9），`符` 切**符号页**（标点 + @#￥%&*），两个页面第 4 行的 `ABC` 回九键

> 词库还是 Android 那 20 个词，超出词库的拼音按完不会有候选（那串数字会被原样上屏）。要扩词库是另一件事，见「下一阶段」。

## 下一阶段（现在没做）

- 中文大词库 / 整句拼音（现在是 20 词精确匹配，换 RIME 或把词库放宿主 App + App Group）
- 军师面板（WebView 不要进键盘，放宿主 App，键盘只读 App Group）
- AI 请求（需要 `RequestsOpenAccess = YES` + 用户开「允许完全访问」）

路线细节见 Android 仓库的 `docs/ios-port.md`。

## License

MIT
