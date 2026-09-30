# 阶段 12E（Final）：微信内闭环 —— 键盘自动发现新聊天

Final 的目标只有一个：**让用户尽量一直待在微信里**。

```
主 App（第一次）→ 开始动态识别 → 选整屏 → 打开「自动同步给狗头军师」→ 切微信
微信聊天变化 → 后台 ScreenCaptureKit → Vision OCR → LiveChatTimeline → 自动同步
  → SharedChatStore（App Group）
  → 用户打开狗头军师键盘：自动检查一次 → 「发现新聊天 · N 条」+「使用最新聊天」
  → 用户点「使用最新聊天」→ Active Context 切到最新
  → 用户点「分析这段聊天」→ AI → 聊天分析 + 对方状态 + 3 条回复
  → 用户点某条 → insertText（到此为止，发送永远由用户自己决定）
```

## 自动检查（不轮询）

- 键盘在**事件节点**检查共享聊天，没有定时器、没有后台死循环、没有文件监听：
  ① 打开狗头军师面板（`showMentorPanel`）；② 键盘重新出现且面板正开着（`viewWillAppear`，
  也覆盖「键盘被系统回收后重建」）；③ 用户主动「读取识别聊天」（原有链路）。
- 检查只做一件事：读一次 `latest_chat.json`，和键盘**已经预览过或使用过**的那份比指纹。
  它**不**替换预览、**不**替换 Active、**不**清当前分析、**不**取消在跑的 AI 请求、**不**调 AI。
- 检查失败（文件不存在 / JSON 损坏 / 容器不可用）是**非破坏性**的：只记一个
  `failedNonDestructive`，当前 Active、分析、三条回复全部原样保留；用户主动「读取识别聊天」时
  仍然按阶段 7 的严格规则处理（失败会清预览等）。

## Fingerprint

`Shared/SharedChatFingerprint.swift`：按顺序拼 `role|text` 再取 SHA-256，App（12D 自动同步）
与键盘（12E 发现新聊天）**共用同一份实现**，免得两端对「是不是同一份聊天」判断不一致。
只看内容不看时间：同一分钟写两次、`updatedAt` 异常都不会漏；内容相同而时间变新也不会反复提示。
指纹只在内存里比较，绝不进正式 JSON；也不用带随机 seed 的 Swift `Hasher`。

## 状态与模型

- `PendingSharedChatUpdate{snapshot, fingerprint}`：只放内存的待处理更新（不写偏好设置、
  不新增 App Group 文件）。
- `SharedChatUpdateState`：`idle / checking / upToDate / available(Pending) / failedNonDestructive`，
  和 `RecognizedChatAnalysisState` 完全分开。
- `SharedChatUpdateDetector.evaluate(shared:knownFingerprint:)`：纯函数，负责比较。

## Banner 与「使用最新聊天」

- 面板主屏在有 pending 时显示「发现新聊天 · N 条」+ 保存时间；如果已经有 Active，
  补一句「使用后会替换当前聊天」，但**不弹确认框**。
- 「使用最新聊天」是用户明确操作，等价于「读取 → 使用」两步，但仍然走
  `SharedChatStore` 与 `GoutouChatClipboard` 的**全部校验**（format / version / role /
  条数 / 单条长度 / 总量 / 时间），不因为自动发现而放行任何东西。
- 点击时：**先**取消在跑的旧 AI 请求并作废旧分析（analysis / tone / replies → idle），
  **再**把 Active 换成最新这份；换完不调 AI，用户仍要点「分析这段聊天」。
- 只是「发现」新聊天时：不取消 AI、不清结果、不换 Active（用户没选择就不能动他的工作）。
- 原来的「读取识别聊天」保留为手动刷新 / 诊断 / 回退入口，行为完全不变。

## 仍然不做的事

不自动 AI、不自动 Token 消耗、不自动插入、不自动发送、不自动 Return、不自动点击微信、
不 Hook / 不注入微信 / 不用私有 API / 不读微信数据库、不写长期人物记忆、不后台轮询。

## 测试

`tools/SharedChatUpdateCheck`（CI 的 `Shared chat update contract`，纯逻辑 + 临时容器，不联网）覆盖：
没有共享聊天不出假更新、没有已知指纹时发现 A、已知就是 A 时 upToDate、A → B 发现更新、
条数相同但正文不同 / 正文相同但 role 不同 / 顺序不同都算更新、内容相同只是时间变新不算更新、
内容变了但时间异常也不漏、重复检查只有一个 pending、pending 会跟到最新一份、
使用最新聊天后 Active / 正文 / role / 顺序正确且预览同步换新、用完指纹记为当前、
使用新聊天清掉旧 analysis / tone / replies 并作废在途请求、仅仅发现新聊天不动分析 / 不换 Active、
检查失败非破坏性、键盘重建后第一次检查就能发现、反复检查不新增文件也不写偏好设置，
以及源码级检查（detector 里没有 AI、输入代理、定时器；`useLatestSharedChat` 分支里没有 AI 调用）。

模拟器 UIKit 回归新增 `testPendingSharedChatBannerRequiresExplicitUse`：横幅文案、时间、
「使用后会替换当前聊天」提示，以及点「使用最新聊天」只发一个 `.useLatestSharedChat`、不触发分析。

## 灵动岛 / 锁屏状态（Live Activity）

动态识别启动后用户基本待在微信，状态得能在系统界面看到：

- `Shared/LiveActivity/GoutouCaptureActivityAttributes.swift`：主 App 与 Widget 扩展**编译同一份**
  属性定义（不复制两份）。静态属性只有一个 `sessionID`；动态 `ContentState` 只有**状态与计数**：
  是否在捕获、门控文案、自动同步文案、实时条数、已同步条数、未确定条数、最后同步时间、错误文案。
  **没有任何聊天正文**，也不放 API Key、不放沙盒路径。
- `App/ScreenCapture/GoutouCaptureActivityState.swift`：纯函数映射 + 规划器。只有真正开始捕获
  （`state == .capturing`）才请求创建一个 Activity；相同状态不重复 update；两次 update 之间至少隔
  1 秒（**绝不按帧推灵动岛**）；停止 / 失败时结束。这些决策不依赖 ActivityKit，所以能在 CI 上单测。
- `App/ScreenCapture/GoutouCaptureActivityController.swift`：唯一碰 ActivityKit 的地方。
  `#if canImport(ActivityKit)` + `#available(iOS 16.2, *)` 隔离；启动新一轮时会先收掉残留的旧
  Activity（不累积多个狗头军师状态）；**任何 ActivityKit 错误只记一句原因**，捕获 / OCR / 时间线 /
  自动同步 / 共享聊天 / 键盘一律照常。
- 只有「有意义的变化」才推：OCR 回来（门控 / 条数 / 未确定变化）、自动同步状态变化（成功 / 失败）、
  捕获开始 / 停止 / 失败。不保存帧历史，不按帧刷新。
- 灵动岛：minimal 只画 🐶；compact 左边图标、右边条数（暂停时是 ⏸）；expanded 左「狗头军师」
  右状态、底部条数 / 已同步 / 未确定。锁屏是同样三行状态 + 计数。**都不出现正文。**

## 控制中心

`Widget/GoutouCaptureControl.swift` 是一个 iOS 18+ 的 `ControlWidgetButton`：点一下**只把 App 打开**
（`openAppWhenRun = true`），没有别的语义。

- 它**不会**、也无法绕过系统的内容共享界面去偷偷开始整屏捕获；
- 它**不会**把「自动同步」变成持久授权（12D 的授权语义一个字没改）；
- 它不碰 AI、不碰聊天存储、不读 API Key。

跨进程没法可靠地操作正在跑的内存里的 capture session，所以 Control 就只做「快捷入口」，
不做「一键开关自动同步」这种看起来方便、实际上不可靠也不安全的事。

## 系统 SDK 核对（先查再写）

写代码前先用一次性 probe workflow 在 `xcode-27` 镜像上实际 typecheck 过 Xcode 27 / iOS 27 SDK：
`ActivityAttributes` 是 `@available(iOS 16.1, *)`，`DynamicIsland` / `ActivityConfiguration`（16.1）、
`ControlWidget` / `StaticControlConfiguration` / `ControlWidgetButton`（18.0）都存在，一整套
「Live Activity + 灵动岛 + Control」在 `-target arm64-apple-ios16.1` 下 typecheck 通过。
所以**不需要**为了这两个能力把项目最低版本提到 iOS 27：主 target 仍是 iOS 16，
Widget 扩展单独设 16.1（ActivityKit 的下限），Control 用 `if #available(iOS 18.0, *)` 隔离。

## 重签时要注意的 capability

Final 仍然是**未签名 IPA**。重签环境要保住这些，否则对应能力只是「没起来」（主链路不受影响）：

- App Group（键盘读写 `latest_chat.json`）——现有那套；
- `NSSupportsLiveActivities`（已在 `App/Info.plist`）与 Widget 扩展的 bundle id
  `com.example.goutouinput.capturewidget`（必须挂在主 App 的 ID 下面）；
- Control / AppIntent 相关 capability 由重签工具按它自己的规则处理；重签后要在真机上确认
  灵动岛与控制中心是否真的出现。

## 测试

`tools/CaptureActivityCheck`（CI 的 `Capture activity contract`，纯逻辑 + 源码契约，不联网）覆盖：
没开始捕获不建 Activity、开始后请求创建、运行期间只 update 不重复创建、条数 / 同步数 / 未确定数
如实映射、内容里不含正文与 URL、相同状态不重复推、过快变化被节流并统计、停止后 end 且不再更新、
失败带着错误状态收尾、新一轮 capture 建新 Activity 且不复用旧的、控制器初始不在跑 / 停止后回到不在跑，
以及源码级检查（新代码里没有 AI / 输入代理 / 聊天存储 / 容器路径 / UserDefaults / `fatalError` / `try!`，
Control 只有「打开 App」语义）。真实的灵动岛、锁屏与控制中心仍然只能真机验收。

**Final 代码、CI 与构建已完成，真实 iPhone / 官方微信端到端最终验收仍需用户完成。**
