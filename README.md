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

**第三阶段（军师链）**

1. 键盘顶栏「军师」→ 整屏换成军师面板
2. 上下文靠剪贴板，手动标归属：`👤对方` / `🙋我` / `📝背景`（背景优先读草稿），段数不限
3. 面板出一行判断（≤20 字）+ 4～6 条话术（区域可滚），点一条直接上屏，不自动发送
4. 接口配置在宿主 App 填 → 「复制配置」→ 键盘 ⚙「从剪贴板导入」，key 只存在手机上
5. 没开「允许完全访问」时面板顶部直接提示，一键复制开启步骤

**明确不做**：不做读屏（iOS 没有对应能力）、不接 Function Kit、不做 App Group、不做中文大词库 / RIME、不做任务/风格选择器。

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
  NineKeyMapper.swift                九键多击字母循环（Android 口径参照，已不在输入路径上）
  GoutouPinyinTable.swift            九键词库：数字串切分 + 候选（约 2 万词 + 两万汉字）
  NineKeyInputEngine.swift           中文九键输入状态机（composing / flush / 回删）
  GoutouPanelView.swift              军师面板（顶栏 / 状态行 / 归属行 / 结果区）
  GoutouConfig.swift                 接口配置（App 与键盘共用同一份结构）
  GoutouPrompt.swift                 prompt 组装 + 一行判断提取
  GoutouAIClient.swift               OpenAI 兼容请求 + 返回解析（纯 Foundation）
  GoutouSegmentStore.swift           军师上下文落盘（存到你手动清空为止）
  GoutouMemoryStore.swift            长期档案（记忆）落盘，每次分析都带上
  GoutouProfileStore.swift           多人档案（人物/上下文/记忆/总结 一人一份 + 老数据迁移）
  GoutouSkill.md                     军师人格，从 Android 仓库原样拷来（口径只有一份）
  Info.plist                         NSExtension: com.apple.keyboard-service
tools/NineKeyCheck/main.swift        九键逻辑冒烟测试（CI 上 swiftc 直接跑，不需要模拟器）
.github/workflows/build-ios.yml      无 Mac 构建流水线
```

两个 target：`GoutouInput`（App）和 `GoutouKeyboard`（app-extension，被嵌进 App 的 `PlugIns/`）。扩展只依赖 UIKit，纯系统控件，没有 WebView、没有第三方库，内存曲线是平的。

### 跨平台复用的那一层

`NineKeyMapper` / `GoutouPinyinTable` / `NineKeyInputEngine` 只依赖 Foundation，不碰 UIKit，
是 Android 那边 `NineKeyMapper.kt` 和 `GoutouInputMethodService` 里跟平台无关的部分：

| Android | iOS |
|---|---|
| `NineKeyMapper.kt`（多击循环、650ms 窗口） | `NineKeyMapper.swift` 逐行对应 |
| `dictionary` map（当年那 20 词） | 已换成 `GoutouPinyinTable.swift` + 生成的两份 TSV（Android 那 20 词不够打字） |
| `composing` / `lastNineKey` / `flushComposing` / `deleteOnce` 的拼音部分 | `NineKeyInputEngine.swift` |
| `renderNineKeyLayout` / `renderCandidateBar` / `handleKey` | `NineKeyKeyboardView.swift` + 控制器里的 `handleNineKeyAction` |

Android 专属的 `InputMethodService`、`View` 树、JNI 一律没搬，按 Keyboard Extension 的
`UIInputViewController` + `textDocumentProxy` 重写。

### 军师链的通道

iOS 上宿主 App 和键盘扩展**没有 App Group 就没法共享数据**（免费 Apple ID 不保证给 App Group），
所以三者之间只有一条通道：**系统剪贴板**。

```
宿主 App 填 Base URL/Model/Key ──「复制配置」──▶ 剪贴板 ──键盘 ⚙「从剪贴板导入」──▶ 键盘 UserDefaults
聊天里长按消息 → 复制 ─────────────────────────▶ 剪贴板 ──👤对方 / 🙋我 / 📝背景──▶ 上下文（段数不限）
上下文 ──键盘内直接发请求（要「允许完全访问」）──▶ 一行判断 + 4～6 条话术 ──点一条──▶ 当前输入框
```

任务/风格写死成 Android 面板的两个默认值（`分析她/他说什么意思` + `自然`）；`relationship`
被要求「第一句必须是一句不超过 20 字的判断」，iOS 只取第一句显示，Android 那边仍然显示全文。

话术条数在 iOS 的 prompt 里改成了 **4～6 条**（skill 原文写的是 2～3 条）——面板嫌 3 条不够挑，
所以在那行契约里明确覆盖。Android/Web 那边没动，仍是 2～3 条。

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

默认进中文九键。顶栏右边那个 🐶 就是军师入口；底部左边「中英」切英文 26 键，26 键底部的「中」切回九键，
切换结果会被记住。

**英文 26 键照 iOS 自带键盘排**：三行字母 + `⇧` / `⌫` 那一行 + 底行 `123` `🌐` `中` `空格` `换行`；
`123` → 数字页（再点一次回字母），数字页的 `#+=` → 更多符号页；`⇧` 只作用一个字母（和系统一样）。
键帽样式也跟着系统键盘走（浅色下白键浅灰底，深色下深灰键近黑底，带一点投影）。

九键的做法是**数字串 → 切出所有可能的拼音组合 → 查词库**（和手机上其他九键输入法一样）：

- 按 `6` `4` `4` `2` `6` → 切出 `ni+hao` → 首选「你好」，点一下上屏
- 单字也行：`6` `4` → 切出 `ni`/`mi`，按常用度给出「你、米、密、尼…」
- 顶部一行显示你按的数字 + **拼音路径**：`64426 · ni'hao`、`946644846 · zhong'guo`；读法有歧义的单音节只显示数字（免得和一个候选对不上）
- `1` 键（键上小字写着「分词」）用来**钉音节边界**：打 `64` → 点 `分词` → 再打 `426`，顶部变成 `64'426`，
  切分被锁成 `ni|hao`，不许跨过这条边界重新组合；同一位置再点一次就取消。中文逗号「，」在左边标点列第一个键，没丢
- `0` / 空格：有候选先上屏首候选，没有就打空格
- `重输` / `清空` 丢掉当前数字序列；`⌫` 先吃数字，数字空了才删正文
- `123` 切**数字页**（完整 0-9），`符` 切**符号页**（标点 + @#￥%&*），两个页面第 4 行的 `ABC` 回九键

词库是打进键盘的两份 TSV（约 500 KB，2 万个词条 + 两万汉字），由 [`tools/fetch-pinyin-data.py`](tools/fetch-pinyin-data.py)
从三份 MIT 数据生成，来源与许可见 [THIRD-PARTY.md](THIRD-PARTY.md)：

| 文件 | 内容 |
|---|---|
| `Keyboard/pinyin-chars.tsv` | 音节 → 候选汉字（含全局常用度排序），417 个音节 |
| `Keyboard/pinyin-words.tsv` | 整串拼音 → 候选词，2 万条 |

排序是**启发式**的：按词频分档排序，个别词（比如 `944826` 会先给「一贯/习惯」再给「喜欢」）不保证顺序最优。

### 军师怎么用

**人物档案（第六阶段）**：面板顶栏中间显示的就是**当前人物**，点它进档案列表——新建 / 切换 / 删除 / 改名。
**每个人的上下文、记忆、AI 总结都是分开的**，切人就是整组换；人格（分析风格）是全体共用一份 `SKILL.md`。
顶栏写的是「狗头军师 · 名字」，一眼知道现在分析的是谁。
档案列表里**点一下切换、长按进管理**（改名 / 删除都在管理页，删除要再点一次确认）。
没有 App Group，所以键盘里没法打字输入名字：**把名字复制过来，在管理页点「✏️ 用剪贴板第一行改名」**。
老版本那份单独存的上下文/记忆会在第一次打开时自动搬进一个叫「默认」的档案，不会丢。

**界面细节**：状态行只写「上下文 N 段 · M 字」，点一下才展开逐段明细（显示哪几段是谁说的）；
归属键有内容就打勾、没内容淡一点（`👤对方 ✓` / `🧠 记忆（1）`）；
分析键三态：`⟳分析` → 分析中（转圈 + 禁用，防重复请求）→ `重新分析`；
分析失败只显示一句人话（「分析失败，返回格式异常」）+「重试 / 查看详情」，技术原文收在详情里；
结果区结构固定（分析结论 + 推荐回复 1./2./3. + 每条一个「插入」），失败时保留上一次的结果，高度不跳。

第一次要配接口（这一步决定了它能不能用）：

1. 宿主 App「狗头军师」里填 Base URL / Model / API Key → 点「复制配置到剪贴板」
2. 切到键盘 → 顶栏「军师」→ ⚙ 设置 → 「⬇️ 从剪贴板导入配置」
3. 回键盘试一次：长按对方的消息 → 复制 → 「军师」→ 👤对方 → ⟳ 分析

之后每次就三步：**复制对方的话 → 点 👤对方 / 🙋我 / 📝背景 → 点 ⟳ 分析 → 点一条话术上屏**。

- `📝背景` 优先读你正在输入框里打的那句草稿（不发出去），读不到才退到剪贴板——用来补「我们上周吵过架」这种对话里没有的信息
- `🧠记忆`（长期档案）是那个「越用越懂你」的地方：把「她生日 3 月 5 日」「我们认识三个月」这类事实复制过来点导入，
  之后**每次分析都会带上**，军师不会反复问你同样的事；每条旁边有 ✕ 可以单独删
- 上下文**段数不限**，面板里会全部列出来，每段右边有个 ✕ 可以单独删；状态行显示总字数，超过 4000 字变橙色提醒（请求会变慢，可能撞上 60 秒超时）
- 上下文**会落盘**（存在键盘自己的 UserDefaults 里），退出面板、切走 App、键盘被系统回收都不会丢；**只有你点「✕ 清空上下文」才会清掉**
- ⚠️ 因为落盘，聊天内容会以明文写进键盘这个 App 的沙盒目录。自用可以接受，但你要知道这件事
- 请求超时 60 秒，失败会给原因 + 「重试」；等待中可以「取消」
- 没开「允许完全访问」→ 面板顶部直接提示，点一下复制开启步骤。**这个开关是军师能不能用的硬前提**（读剪贴板、联网都靠它）
- 话术只填进输入框，**不会自动发送**

## 下一阶段（现在没做）

- 整句输入 / 联想（现在是"数字串切拼音 + 词库命中"，没有再往上做整句模型；要更进一步就得考虑 RIME）
- 任务/风格选择器（iOS 面板现在写死 Android 的两个默认值）
- 宿主 App 里的完整面板 + 历史（现在是"键盘内面板 + 剪贴板传配置"）

路线细节见 Android 仓库的 `docs/ios-port.md`。

## License

MIT
