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

**当前增量（截图 OCR 第一阶段）**：主 App 新增「识别聊天截图」页 —— 你自己选一张聊天截图 →
本机 Vision OCR（不保存图片、不上传）→ 整理消息并按版式判断归属（判不出来标「未确定」）→
你改文字 / 改归属 / 删无关行 → 点「复制聊天文字」写出带 `format`/`version` 标记的 JSON。

**第二个增量（截图 OCR 第二阶段：结果清理与归属改进）**：归属改成看**气泡边缘**而不是文字框
（真机上右侧 6 条绿气泡的右边缘是同一个常数 0.8646…0.8672，文字框边缘不是），
顶部状态栏 / 聊天标题 / 底部输入区按内容边界自动剔掉，
居中的日期时间与通话记录标成「非聊天候选」（默认不复制、一键可放回），
表情被认成 `C`/`こ` 这类杂字时只给「去掉末尾杂字」的建议、不自动改正文。
细节、判据和已知限制见 [截图 OCR 第二阶段说明](docs/phase-2-chat-ocr.md)，
第一阶段的支持范围见 [截图 OCR 第一阶段说明](docs/phase-1-chat-ocr.md)。

**第三个增量（共享聊天预览）**：主 App 修正结果后点「保存给狗头军师」，
键盘军师面板点「读取识别聊天」可查看条数、时间与按顺序排列的归属和正文。
沿用已验证的 App Group 和固定 probe；保存为原子文件，剪贴板复制仍保留。
超过 30 分钟提醒可能较旧，读取失败清除旧预览。清除共享聊天与清空 OCR 结果分开。
签名服务组内的项目子目录不提供应用隔离。预览不接入上下文、AI、人物档案或记忆。
实现与真机验收步骤见 [共享聊天预览说明](docs/phase-3-shared-chat.md)。

**第四个增量（识别聊天临时上下文）**：预览仍然只是预览，键盘里再点一次
「使用这份聊天」才会变成狗头军师正在使用的临时上下文，显示「已使用识别聊天 · N 条」，
可以「取消使用识别聊天」（只取消使用，不删共享文件）。重新读取会先作废旧上下文，
读取失败不会留下旧聊天；临时上下文只活在键盘内存里，不落盘、不写记忆、不调用 AI。
细节见 [识别聊天临时上下文说明](docs/phase-8-recognized-chat-context.md)。

**第五个增量（识别聊天分析）**：面板里多一个「分析这段聊天」，只有用户主动点它才会把
正在使用的识别聊天发给现有 AI 网络层，回来显示**一份聊天分析**。阶段 9 的 Prompt 单独一份
（`RecognizedChatPrompt`，只要求 `analysis` 字段），旧的军师 Prompt 与推荐回复链路一个字没动；
不生成推荐回复、不插输入框、不写记忆、不落盘，读取或使用聊天都不会偷偷发请求。
细节见 [识别聊天分析说明](docs/phase-9-chat-analysis.md)。

**第六个增量（结构化结果 + 三条推荐回复）**：识别聊天的分析升级成正式契约——
【聊天分析】+【对方状态】+【推荐回复】恰好 3 条。解析宽容（字段名和旧格式都能认、代码围栏、
thinking 片段），但进界面前严格归一化：空、纯标点、完全重复都丢掉，超长截断，不足 3 条就报错。
三条候选本阶段只展示（只读卡片，不是「发送」按钮）。旧军师 Prompt 与 6～8 条契约没动。
细节见 [结构化结果说明](docs/phase-10-structured-replies.md)。

**第七个增量（候选回复上屏）**：三条推荐回复从只读卡片变成可点卡片，点哪条就把哪条的
**原文**插进当前输入框（序号只是标题），不清草稿、不加空格换行、不模拟回车、不发送、
不重新分析、不写记忆。旧卡片在结果失效后插不进去。细节见
[候选回复上屏说明](docs/phase-11-insert-reply.md)。

**第八个增量（动态屏幕识别 · 12A）**：主 App 新增「动态识别测试」——用户主动点按钮调起
系统内容共享界面、选整屏后，用 ScreenCaptureKit 持续收帧，在本机用 Vision 识别画面文字并显示
（含帧数 / 识别次数 / 最后时间）。识别在内存里完成：不保存截图、不写 App Group、不联网、
不自动分析、不调 AI。功能隔离在 iOS 27+，其余功能不受影响；CI 因此改用 `xcode-27` 镜像。
细节见 [动态屏幕识别 12A 说明](docs/phase-12a-live-screen-capture.md)。

**第九个增量（实时聊天时间线 · 12B）**：动态识别页多了「实时聊天」——把每一屏的 OCR 文字
过滤掉标题栏与键盘、把多行合成一条消息、按水平几何保守判断「我 / 对方 / 未确定 / 系统」、
连续两帧稳定后才进时间线，并用连续序列 overlap 合并滚动（同一消息不会重复堆叠）。
时间线只放内存（上限 200 条），可以「清空实时聊天」而不停止捕获；不写共享聊天、不调 AI、不碰键盘。
细节见 [实时聊天时间线说明](docs/phase-12b-live-chat-timeline.md)。

**第十个增量（实时聊天确认 → 共享给键盘 · 12C）**：实时时间线不再只是看——点「整理当前实时聊天」
会把这一刻冻结成一份确认草稿（捕获照常继续、草稿不会跟着跳），逐条核对归属与正文、可排除，
点「保存给狗头军师」后走**现有 SharedChatStore** 写进 App Group，键盘照旧「读取识别聊天」。
未处理的「未确定」会拦住保存；不自动保存、不调 AI、不插入、不发送、不改键盘。
细节见 [实时聊天确认说明](docs/phase-12c-live-chat-review.md)。

**第十一个增量（自动同步给狗头军师 · 12D）**：动态识别页多了「自动同步给狗头军师」开关——默认关闭、
每轮捕获都要重新授权。开启后，稳定且角色明确的实时聊天会在停止变化约 1.5 秒后自动更新到共享聊天
（同一份内容不重复写、同一时刻只有一个写入、失败不疯狂重试）；出现「未确定」消息会整次暂停并保留
上一份成功结果。人工确认保存过的结果优先级最高，会自动暂停同步、必须再次主动开启。
不自动调 AI、不自动激活键盘上下文、不自动插入、不发送、不改键盘。
细节见 [自动同步说明](docs/phase-12d-live-chat-auto-sync.md)。

## 最终能力（Final / 12E 封板）

项目现在已经是一条完整闭环（**AI 与发送始终由用户手动触发**）：

```
截图 OCR ──┐
           ├─→ 人工确认/修正 ─→ SharedChatStore（App Group）
动态识别 ──┘   （ScreenCaptureKit + Vision）        │
                      │                            │
                      ├─→ 自动同步（默认关闭，用户手动开）┘
                      │
                      └─→ 灵动岛 / 锁屏状态
                          （只有状态与计数，没有正文）

SharedChatStore ─→ 键盘「读取识别聊天」/ 自动「发现新聊天 · N 条」
                      ↓
                   「使用最新聊天」─→ Active Context
                      ↓
                   「分析这段聊天」─→ AI
                      ↓
                   聊天分析 + 对方状态 + 恰好 3 条回复
                      ↓
                   点一条 ─→ 只插入输入框（不自动发送，永远由用户决定）
```

- 键盘只在**事件节点**检查共享聊天（面板打开 / 键盘重新出现 / 手动读取），**不做任何轮询**；
  发现新聊天只提示，用户点「使用最新聊天」才切换上下文，并且会一并作废旧分析。
- **灵动岛 / 锁屏 Live Activity**（`Shared/LiveActivity` + `Widget` 扩展）只显示**状态与计数**
  —— 识别中 / 已暂停、实时条数、已同步条数、未确定条数、最后同步时间 —— **绝不出聊天正文**，
  只有真正开始捕获才创建，相同状态不重复推、两次更新至少隔 1 秒，停止 / 失败就收掉；
  ActivityKit 起不来只是「状态没显示」，识别链路照常。控制中心是一个 iOS 18+ 的
  `ControlWidgetButton`，点一下**只把 App 打开**，不绕系统整屏共享授权、不改自动同步授权语义。
- 动态屏幕识别需要 **iOS 27 + 用户主动在系统界面共享整屏**；项目最低 deployment target 仍然是
  **iOS 16**，截图 OCR、键盘、AI 分析、回复插入这些旧功能**都不依赖** ScreenCaptureKit。
- 12D 的自动同步安全规则保持不变：默认关闭、每个 capture session 重新授权、unknown 阻止整次同步、
  system 排除、fingerprint + debounce（1.5s）+ 最低写入间隔（2s）、人工 Review 保存成功后自动暂停。
细节见 [键盘内闭环说明](docs/phase-12e-in-keyboard-handoff.md)。

## 工程结构

```
project.yml                          XcodeGen 工程描述（仓库里不放 .xcodeproj）
App/                                 宿主 App：配置接口 + 截图 OCR
  GoutouInputApp.swift
  ContentView.swift                  入口：自测输入框 + 配置 + 「识别聊天截图」入口
  ChatOCRView.swift                  选图 / 可编辑结果 / 复制（识别任务带请求标识，可取消可作废）
  ChatOCRService.swift               本机 Vision OCR：长图按计划分片识别，坐标换算回原图归一化
  ChatLayoutParser.swift             阅读顺序整理 + 按气泡边缘轨道判归属 / 聊天区域过滤（纯 Foundation）
  Info.plist
Shared/                              两端共用（键盘编译契约、共享存储和 probe）
  SharedChatStore.swift              latest_chat.json 原子保存、校验读取与清除
  GoutouChatClipboard.swift          goutou-chat JSON 契约与编解码（含 version 严格校验与体量上限）
  GoutouChatOCRGeometry.swift        长图分片几何：缩放口径 / 切片 / 坐标换算 / 重叠去重（纯 Foundation）
  GoutouChatBubbleScanner.swift      气泡边缘扫描：底色估计 / 行内色块 / 头像侧（纯 Foundation，有测试）
  SharedChatFingerprint.swift        共享聊天指纹（role|text 顺序拼接后 SHA-256，App 与键盘共用）
  LiveActivity/
    GoutouCaptureActivityAttributes.swift  灵动岛 / 锁屏的属性与 ContentState（App 与 Widget 扩展共用同一份）
Widget/                              灵动岛 / 锁屏状态 + 控制中心快捷入口（WidgetKit 扩展）
  GoutouCaptureWidgetBundle.swift    WidgetBundle：Live Activity + Control
  GoutouCaptureActivityWidget.swift  锁屏与灵动岛（minimal / compact / expanded），只画状态与计数
  GoutouCaptureControl.swift         控制中心按钮（iOS 18+）：点一下只把 App 打开
  Info.plist                         NSExtension: com.apple.widgetkit-extension
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
  PersonMemory.swift                 记忆条目模型（UUID 永久身份 / 分类 / 来源追踪 / 归档位）+ 候选事务合并
  GoutouMemoryRepository.swift       记忆唯一访问层：按 personID 隔离、按 id 操作、时间字段规则
  MemoryRankingConfig.swift          记忆排序的全部权重与预算（Top-K / 字符预算 / 类别优先级）
  MemoryDecayConfig.swift            时间衰减 / stale 参数（近况 0-7 天新鲜、7 天后平滑衰减、60 天后算可能过时）
  MemoryMaintenance.swift            记忆整理：同类别高度相似才合并、过期近况才归档（只归档不删除）
  MemoryManagement.swift             记忆管理页的数据层：列表 / 搜索 / 筛选 / 详情 / 编辑草稿 / 归档恢复确认
  MemorySelector.swift               相关记忆筛选：本地评分 + 保底 + 近义降权 + 预算（不引 Embedding）
  GoutouMemoryExtractor.swift        分析成功后的自动归纳（提取候选，不存原文；不改网络层）
  GoutouProfileStore.swift           多人档案（人物/上下文/记忆/总结 一人一份 + 老数据迁移）
  GoutouSkill.md                     军师人格，从 Android 仓库原样拷来（口径只有一份）
  Info.plist                         NSExtension: com.apple.keyboard-service
tools/NineKeyCheck/main.swift        九键逻辑冒烟测试（CI 上 swiftc 直接跑，不需要模拟器）
tools/ChatLayoutCheck/main.swift      剪贴板契约 / 版式解析 / 长图分片几何 / 气泡扫描冒烟测试（纯 Foundation）
tools/ChatLayoutCheck/ScreenshotFixtures.swift  匿名化的真实版式回归样例（文字全是占位内容）
tools/ChatVisionCheck/main.swift      真 Vision 的合成截图回归（只在 macOS runner 上跑）
.github/workflows/build-ios.yml      无 Mac 构建流水线
```

三个 target：`GoutouInput`（App）、`GoutouKeyboard`（app-extension，键盘）、
`GoutouCaptureWidget`（app-extension，灵动岛 / 锁屏状态 + 控制中心），两个扩展都被嵌进 App 的 `PlugIns/`。
扩展只依赖 UIKit / WidgetKit / ActivityKit，纯系统控件，没有 WebView、没有第三方库，内存曲线是平的。

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

现有接口配置和手动聊天上下文继续使用系统剪贴板。**App 与键盘之间只有剪贴板这一条通道**：
早期那套「共享聊天缓存走 App Group」的路线已经废弃删除（买的签名服务不能定制 App Group，
那份通道在两端口令不一致时还会假装通信成功）。

```
宿主 App 填 Base URL/Model/Key ──「复制配置」──▶ 剪贴板 ──键盘 ⚙「从剪贴板导入」──▶ 键盘 UserDefaults
聊天里长按消息 → 复制 ─────────────────────────▶ 剪贴板 ──👤对方 / 🙋我 / 📝背景──▶ 上下文（段数不限）
上下文 ──键盘内直接发请求（要「允许完全访问」）──▶ 一行判断 + 4～6 条话术 ──点一条──▶ 当前输入框
```

截图 OCR 那一半（**做到复制为止，键盘侧的导入还没接**）：

```
主 App「识别聊天截图」← 你主动选图 ──▶ 本机 Vision OCR ──▶ 整理 + 判归属 ──▶ 你改 ──▶ 点「复制聊天文字」
                                                                                      └─▶ 剪贴板里是 goutou-chat JSON
                                                                                          （键盘暂时还读不到它）
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

**返回格式的兜底**：接口回来的东西不一定规矩。解析顺序是
① 严格 JSON → ② 去代码围栏 → ③ 从正文里抠出配平的 JSON 对象 → ④ 修尾逗号 → ⑤ **按字段名切片**
（对付值里没转义的引号、字符串里的裸换行、甚至被截断的 JSON）。
五种都读不出来时才报错，这时错误里会带出返回的开头，方便定位；
如果本来就 `finish_reason=length`，会直接说「模型输出被截断」，而不是含糊的「格式异常」。
**推理模型（deepseek-reasoner 这类）**：它会把过程写在 `reasoning_content`、`content` 留空。
这种情况会先从 `reasoning_content` 里再捞一次（有些模型把结论也写在思考里），
还捞不到就明说「模型只回了思考、没有正文，把 Model 换成非推理的（如 deepseek-chat）」。
`max_tokens` 也提到了 8192，给思考＋正文留足余量（思考是从同一个预算里扣的）。

**记忆会自动长**：每次分析成功之后，键盘会用同一套接口再跑一次「归纳」——
只把这次聊天里**值得长期留下的事实/近况**提炼成几句（**不保存聊天原文**），
再和你已有的记忆比对，按 `ADD / UPDATE / MERGE / IGNORE` 合并：
同一个意思不会反复新增，新信息会覆盖旧的那条，AI **只能改不能删**。
归纳完主界面只提示一句「已从本次聊天更新 X 条记忆」。
归纳这一步失败（超时/格式不对）时**记忆一个字都不动**。
记忆分「稳定事实」和「近期状态」两类分开存，记忆页里也分两段列。

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

- **动态屏幕识别（12A～12E 已完成主体）**：截图 OCR、动态识别、实时时间线、人工确认、自动同步、
  键盘自动发现新聊天、灵动岛 / 锁屏状态、控制中心快捷入口、分析 + 恰好 3 条回复、点一条只插入，
  已经连成一条闭环；剩下的是**真机验收**（官方微信 + ScreenCaptureKit + 灵动岛 + 重签环境）。
- **表情/图片消息的留位**：现在整条只有一个表情的消息（Vision 认不出文字）**不会出现**在结果里，
  要补上得把整张图的气泡做二维分割，这一阶段没做。
- 整句输入 / 联想（现在是"数字串切拼音 + 词库命中"，没有再往上做整句模型；要更进一步就得考虑 RIME）
- 任务/风格选择器（iOS 面板现在写死 Android 的两个默认值）
- 宿主 App 里的完整面板 + 历史（现在是"键盘内面板 + 剪贴板传配置"）

路线细节见 Android 仓库的 `docs/ios-port.md`。

## License

MIT
