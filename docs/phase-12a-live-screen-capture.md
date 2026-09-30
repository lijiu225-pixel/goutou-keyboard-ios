# 阶段 12A：用户授权整屏捕获 + 本机 OCR

目标只有一个：证明**在真实 iPhone 上**，用户主动启动系统屏幕共享后切到微信，
主 App 即使进了后台仍能持续收到整屏画面帧，并在本机用 Vision 把画面文字识别出来。

本阶段**不做**：自动 AI 分析、三条回复、自动插入、自动发送、聊天去重、消息历史合并、
我/对方归属、气泡判断、人物记忆；也不让键盘扩展偷偷截屏。

## 真实 SDK 事实（动手前用 CI 探针查过，不是照提示词写的）

- Apple 文档：iOS 版 ScreenCaptureKit 与 `SCStream` 都是 **iOS 27.0+**。
- 我们的 runner：`macos-15` 的 iPhoneOS SDK 只有 26.2、`macos-26` 只有 26.5，
  SDK 里**没有** `ScreenCaptureKit.framework`，`import ScreenCaptureKit` 直接 `no such module`。
- GitHub 的 **`xcode-27` 预览镜像**：Xcode 27.0（27A266a）+ **iPhoneOS 27.0 SDK**，
  `ScreenCaptureKit.framework` 存在，`SCStream` / `SCStreamOutput` / `SCContentFilter` /
  `SCContentSharingPicker` 在 `arm64-apple-ios27.0` 下 typecheck 通过。
- 因此本阶段把 workflow 的 `runs-on` 从 `macos-15` 换成 `xcode-27`（还是同一套 CI，不新建第二套）。

## 与提示词不一致、实现时按真实 SDK 走的两个点

1. **`allowedPickerModes` 在 iOS 上不可用**：`SCContentSharingPickerMode` 整个枚举和
   `SCContentSharingPickerConfiguration.allowedPickerModes` / `excludedWindowIDs` /
   `excludedBundleIDs` / `allowsChangingSelectedContent` 都标着 `API_UNAVAILABLE(ios, ...)`。
   所以「限定整屏」不能程序化强制，改成：`present(using: .display)` 引导 +
   界面文字提示「请选整屏 / Entire Display」。
2. **`SCStreamConfiguration` 在 iOS 上属性更少**：`minimumFrameInterval`、`pixelFormat`、
   `queueDepth` 等 iOS 上都不可用 → 帧率节流必须自己写（本阶段就是自己节流），
   像素格式按实际到达的样本处理。Vision 直接吃 `CVPixelBuffer`，不转中间图片。

可用且已验证的 Swift 名字：`SCContentSharingPicker.shared`、`isActive`、`isAvailable`、
`present()`、`present(using:)`、`add(_:)` / `remove(_:)`，
观察者三个方法 `contentSharingPicker(_:didUpdateWith:for:)` / `didCancelFor:` /
`contentSharingPickerStartDidFailWithError(_:)`，`SCStream(filter:configuration:delegate:)`、
`try addStreamOutput(_:type:sampleHandlerQueue:)`、`try await startCapture()` / `stopCapture()`、
`try removeStreamOutput(_:type:)`、`isCapturing`，帧方向来自
`SCStreamFrameInfo.videoOrientation`（取值遵循 `CGImagePropertyOrientation`）。

## 捕获 / OCR 数据流

```
用户点「开始动态识别测试」
  → SCContentSharingPicker.shared（add 观察者、isActive = true、present(using: .display)）
  → 系统内容共享界面（用户明确选整屏）
  → observer didUpdateWith filter（拿到 SCContentFilter）
  → SCStream(filter:configuration:delegate:)，capturesAudio = false
  → addStreamOutput(_, type: .screen, sampleHandlerQueue: 串行队列) → startCapture
  → 每帧：校验 CMSampleBuffer → 取 CVPixelBuffer + 帧方向（都在 sample 队列上）
  → 主线程只做计数与决策（模型）
  → 需要识别时把 CVPixelBuffer 交给独立 OCR 队列
  → Vision VNRecognizeTextRequest（.accurate + 语言纠正 + 简中/英文）读 CVPixelBuffer
  → 按视觉顺序排序 → LiveOCRSnapshot（只放内存）→ 主线程更新界面
```

停止：`beginStop()` → `removeStreamOutput` + `stopCapture` → 释放 stream 与观察者 →
`captureDidStop()`。多次停止安全；停止后迟到的 OCR 结果因代际号不匹配被丢弃。

## 节流与内存

- `ocrMinimumInterval = 0.8s`：最多每 0.8 秒跑一次 OCR，绝不每帧都跑。
- 同一时刻只允许一个 OCR 在跑；期间只保留**最新一帧**（`maximumPendingFrames = 1`）。
- OCR 结束时有 pending 帧且窗口允许 → 立刻处理它；否则按设计安全丢帧（计入 `droppedFrames`）。
- 只保存一份最新 `LiveOCRSnapshot`，不留帧历史、不录像。

## 后台模式与工程配置

主 App `Info.plist` 增加 `UIBackgroundModes = [screen-capture]`（Apple 文档里确有该取值），
只加这一项，不加 audio / location / bluetooth / voip；Keyboard Extension 一字未改。
deployment target 仍是 iOS 16.0，功能用 `#if canImport(ScreenCaptureKit)` + `#available(iOS 27.0, *)`
隔离：旧系统上入口会显示「需要 iOS 27 或更高版本」，截图 OCR / 军师分析 / 回复插入全部照常。

## 测试

`tools/LiveScreenCaptureCheck`（CI 的 `Live screen capture contract`，纯逻辑、不联网）覆盖：
初始 idle、unsupported、开始流程进入 presentingPicker → starting → capturing、
picker 取消、捕获中重复开始被挡、多次停止安全、帧计数、节流窗口内只跑一次、
过窗可再跑、OCR 期间不并发且只留最新帧、完成后处理 pending 帧、成功替换 snapshot、
OCR 失败不停 stream、停止后迟到结果不写回、stream 挂了进 failed 且可重启、
阅读顺序（上→下、同行左→右、空白行丢弃）、一整轮不写文件 / 不写共享聊天 / 不写 UserDefaults，
以及动态识别模块源码里不出现 AI 客户端、输入代理、存图、麦克风相机、记忆相关调用。

**模拟器不能证明真实整屏捕获**：`SCContentSharingPicker` / `SCStream` / 微信前台跨 App 捕获
只能由真机验证。

**阶段 12A ScreenCaptureKit 跨 App 动态 OCR 尚待真机验收。**

## 真机验收步骤

1. 重签安装阶段 12A 的新 IPA，确认键盘已启用、完全访问已开启
2. 打开主 App → 进「动态识别测试」→ 点「开始动态识别测试」
3. 系统内容共享界面出现 → 选**整屏 / Entire Display** → 确认系统开始共享
4. 切到官方微信，打开一个**测试聊天**，停留 5~10 秒，并轻微上下滚动一次
5. 回到主 App，确认状态仍是「正在捕获」、「收到屏幕帧」> 0、「执行识别次数」> 0
6. 检查「最新识别文字」里能看到刚才微信界面上确实可见的部分文字
7. 点「停止动态识别」，确认停止后计数不再增加，且再点一次停止不会出问题
8. 确认系统相册里没有自动保存的截图 / 视频，确认没有任何 AI 分析被触发
9. 再启动一次，确认可以重新工作
