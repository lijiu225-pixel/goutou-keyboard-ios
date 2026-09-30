# FINAL：使用与验收

范围止于现有输入法最后一次集成，不创建 12F、12G 或 13。除真实验收发现明确 Bug 外，不扩展功能。

## 数据流与边界

主 App 用户授权整屏共享 → ScreenCaptureKit → 0.8 秒节流 → fast OCR / 标题区域 OCR / 矩形几何场景检测 → ChatSceneGate → 完整 Vision OCR → LiveChatScenePipeline → LiveChatSystem / Timeline → LiveChatAutoSyncCoordinator → SharedChatStore → App Group。

门控保持 unknown、candidate、activeChat、inactive。连续 2 个聊天检测帧进入，连续 3 个非聊天帧退出。滞回保留 UI 稳定状态，但不把可疑画面提交到 Timeline。标题仅取顶部中间区域，排除侧边返回按钮与状态栏；不同标题连续确认期间隔离新帧。聊天区域的底部边界按本帧检测到的输入栏或键盘位置动态收紧，键盘弹出后的键盘文字不进时间线。即使两个联系人的标题相同，只要离开过聊天界面，恢复提交前也要重新确认并开启新的 chat generation；确认换标题、无可靠 overlap 同样重开 generation，宁可截断也不拼接不同联系人。矩形几何支持没有可识别正文的图片、视频与语音布局；效果仍需真实微信测试，不宣称覆盖全部主题和机型。

每一帧只允许一份等待主线程的投递，OCR 未完成时后续帧直接丢弃，不在主线程堆积帧任务。

Auto Sync 默认关闭，每次 capture 重新授权。system 排除，unknown 阻止整次同步，debounce 1.5 秒、最低写间隔 2 秒，相同内容不推迟原期限、不重复写。SHA-256 使用 UTF-8 长度界定消息角色、正文和顺序，避免正文换行形成消息边界碰撞。同步串行、不并发保存、Stop 取消排队；同步文件写入与 Stop 失效使用短临界区。人工 Review 保存与自动保存使用同一 OCR 串行队列，人工成功后立刻暂停自动同步。

键盘狗头 → showMentorPanel → checkForSharedChatUpdate → SharedChatAutoLoader → SharedChatStore.read 完整校验 → 与当前 Active 的 fingerprint 比较。新内容取消旧任务、invalidate analysis generation、清旧 analysis / tone / replies，直接采用。相同内容与失败读取保持旧 Active 和分析。键盘重建后再次点击即可从磁盘恢复，不使用高频轮询。

自动载入组件没有网络请求或输入代理能力。只有用户点“分析这段聊天”进入识别聊天 AI 请求。三条候选由既有结果验证器约束；用户点候选通过既有 RecognizedReplyInsert 调用 textDocumentProxy.insertText。不会调用发送、Return、微信内部 UI 或私有 API。

## 状态显示

现有 Widget Target 复用。捕获真正成功后创建 Activity；相同状态不更新，短时间变化合并，至少 1 秒更新间隔，尾随定时器确保最后一次状态交付。停止结束 Activity，重复启动事件不重复创建，ActivityKit 失败不影响主链路。

Compact：paw + 条数 / ● / ! / Ⅱ。Minimal：短状态符号，避免系统选择 minimal 时只显示 paw。Expanded 和锁屏：聊天状态、自动同步状态、实时/已同步/unknown 数量、最近同步时间。ContentState 只含状态与数字；失败原因映射为固定提示，不传任意错误原文。

Apple 系统决定何时采用 minimal、compact 或 expanded；长按可查看 expanded。代码和模拟器构建不等于真实 Dynamic Island 展示验收。

## 构建验证

沿用 `.github/workflows/build-ios.yml`：vision-regression = macos-15，build = xcode-27。运行所有原有 Check 与 PanelUITests，新增 SharedChatAutoLoadCheck、生产门控管线覆盖、Activity 尾随/隐私覆盖，以及三项基线红绿对照。构建 App、Keyboard、Widget 模拟器产品，运行 UIKit 测试，执行 unsigned device Archive。

最终证据必须取自交付 HEAD 的 Actions 日志，包括真实 BUILD SUCCEEDED、TEST SUCCEEDED、ARCHIVE SUCCEEDED；本说明自身不代表它们已经执行成功。最终运行 URL、IPA 大小与 SHA-256 随交付报告提供。所有 fixture 为虚构内容。

## 重签要求

- 主 App：com.example.goutouinput；Keyboard：com.example.goutouinput.keyboard；Widget：com.example.goutouinput.capturewidget。若工具改 Bundle ID，必须同步配置相应 App ID 和 profile。
- App 与 Keyboard 保留相同 App Group entitlement（以 SharedConstants 和两个 entitlements 文件为准），两个 profile 均须授权该组，不能只修改字符串。
- 保留键盘 extension point com.apple.keyboard-service、RequestsOpenAccess=true；用户仍需在设置开启完全访问。
- 保留主 App 的 screen-capture background mode、ScreenCaptureKit 链接及相应平台授权；动态识别需要 iOS 27+ 与用户系统整屏选择。
- 保留嵌入 Widget、对应 provisioning/signature、com.apple.widgetkit-extension 与主 App NSSupportsLiveActivities。Widget 不读 App Group，不应凭空增加它不需要的 entitlement。Live Activity 不是一个可随意添加的自定义 entitlement。
- unsigned IPA 不带可安装签名。CI 成功不保证重签服务保留 App Group、屏幕捕获或 Live Activity 能力。

## 真机验收清单

1. 重签安装 FINAL IPA，启用键盘并开启完全访问；配置 AI。主 App 开始动态识别 → 系统选择整屏 → 主动开启自动同步 → 确认 Live Activity → 切微信。
2. 微信首页停留，应暂停；进入联系人聊天，几秒后开始识别；退出后暂停，再进入自动恢复，无需回主 App。
3. 展示左右几条消息，等稳定后点击**键盘狗头**。无需读取/使用按钮，直接显示“已自动载入最新聊天 · N 条”；此时没有 AI 请求。
4. 手动点“分析这段聊天”，确认分析、对方状态与恰好 3 条回复。点一条，仅插入输入框，不自动发送。
5. 出现新消息后重新点击狗头，自动载入、清旧分析与回复；不自动分析。同聊天反复打开保留结果。
6. 切换联系人 A → B，确认 Timeline 没有混入 A。试相同标题、标题 OCR 丢失、长文本、滚动和重复消息；不连续时允许保守重新积累。
7. 联系人列表、发现、设置、桌面、短视频停留，Timeline 不增长、不保存新聊天，状态暂停。图片、视频、语音多的聊天页验证能恢复；记录真实误判以便修复。
8. unknown 出现时整次同步暂停，上一份 Shared Chat 保留，Activity 显示 unknown 数。必要时回 App 人工修正并保存，确认 Auto Sync 暂停且人工结果不被覆盖。
9. 长按灵动岛查看 expanded，检查计数、同步状态、时间；锁屏检查状态与计数不含正文；其他 Activity 并存时检查 minimal 短状态。
10. Stop 后 Activity 结束；再次 Start 是新 Activity，Auto Sync 关闭，重新授权可继续。测试系统终止共享、重建 Keyboard、共享文件不可用时的恢复与旧结果保留。
11. 回归九键、拼音、候选、数字、符号、空格、删除、回车。连续运行 15–30 分钟，期间进入/退出/滚动/新消息，确认无崩溃、无明显持续卡顿，OCR 不永久停止，Stop 后可重启。

真实 iPhone / 官方微信 / ScreenCaptureKit / Dynamic Island / 重签环境端到端验收由用户完成。验收通过后封板，不继续增加阶段或新功能。
