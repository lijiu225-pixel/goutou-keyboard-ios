import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import SwiftUI

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// 阶段 12A：整屏捕获管理器。
///
/// 只在主 App 里：键盘扩展绝不碰屏幕捕获。
/// 用户主动点「开始」才调起系统内容共享 picker；拿到 `SCContentFilter` 才建 `SCStream`；
/// 帧只用于本机 Vision OCR——不落盘、不上传、不写共享聊天、不碰人物记忆、不调用 AI。
///
/// iOS 上 `SCContentSharingPickerConfiguration.allowedPickerModes` 标注为
/// `API_UNAVAILABLE(ios)`，所以「整屏」只能靠 `present(using: .display)` + 界面文字引导，
/// 不能程序化强制。
@MainActor
final class LiveScreenCaptureManager: ObservableObject {

    @Published private(set) var model: LiveScreenCaptureModel
    /// 阶段 12B 的实时聊天快照（只读给界面）。
    @Published private(set) var chat = LiveChatSnapshot.empty
    /// 阶段 12C：冻结出来的确认草稿（nil = 没在确认）。和实时 chat 是两份状态，互不影响。
    @Published var reviewDraft: LiveChatReviewDraft?
    /// 保存结果提示（成功或失败），只给人看。
    @Published private(set) var reviewNote: String?
    /// 阶段 12D：自动同步状态（默认关闭，只有用户主动开启才会写共享聊天）。
    @Published private(set) var autoSyncState: LiveChatAutoSyncState = .disabled
    /// 阶段 12E：当前屏幕是不是聊天会话界面（门控结果，只用来显示，不含任何正文）。
    @Published private(set) var sceneVerdict: ChatSceneVerdict = .unknown
    @Published private(set) var autoSyncLastSyncAt: Date?
    @Published private(set) var autoSyncLastCount = 0

    private let sampleQueue = DispatchQueue(label: "goutou.live.capture.samples")
    private let ocrQueue = DispatchQueue(label: "goutou.live.capture.ocr", qos: .utility)
    private let chatEngine = LiveChatEngineBox()
    private let captureFence = LiveCaptureFence()
    private nonisolated let frameDeliveryGate = LiveFrameDeliveryGate()
    /// 阶段 12D 的自动同步：和聊天引擎同一条串行队列，不需要额外加锁。
    private let autoSync: LiveChatAutoSyncCoordinator
    /// 灵动岛 / 锁屏状态（ActivityKit 失败只记原因，绝不影响识别链路）
    private let captureActivity = GoutouCaptureActivityController()
    /// 一轮 capture session 的标识：换了 session 就用新的 Live Activity
    private var captureSessionID = UUID().uuidString
    /// OCR 在跑时最多留一帧最新画面（SCStream / bridge 都是 Any，靠 availability 再转回来）。
    private var stream: AnyObject?
    private var pickerBridge: AnyObject?
    private var streamBridge: AnyObject?
    private var pendingFrame: (pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)?

    init() {
        model = LiveScreenCaptureModel(isSupported: LiveScreenCaptureManager.isSystemSupported)
        autoSync = LiveChatAutoSyncCoordinator(queue: ocrQueue)
        let fence = captureFence
        autoSync.canSave = { fence.isActive }
        autoSync.saveSafely = { try fence.whileActive($0) }
        autoSync.onStateChange = { [weak self] state, lastSyncAt, lastCount in
            let token = fence.currentToken
            Task { @MainActor in
                guard let self, token == self.model.generation else { return }
                self.autoSyncState = state
                self.autoSyncLastSyncAt = lastSyncAt
                self.autoSyncLastCount = lastCount
                // 同步成功 / 失败也是「有意义的状态变化」：这时候推一次灵动岛。
                self.captureActivity.stateChanged(self.captureActivityContent())
            }
        }
    }

    /// UI 开关：只有「关闭」和「人工保存后暂停」算没开。
    var isAutoSyncEnabled: Bool {
        switch autoSyncState {
        case .disabled, .pausedAfterManualSave: return false
        default: return true
        }
    }

    /// 把当前状态映射成灵动岛 / 锁屏要显示的内容：**只有状态与计数，没有正文**。
    private func captureActivityContent() -> GoutouCaptureActivityContent {
        GoutouCaptureActivityContentBuilder.make(
            captureState: model.state,
            verdict: sceneVerdict,
            autoSync: autoSyncState,
            timelineCount: chat.messages.count,
            unknownCount: chat.unknownCount,
            syncedCount: autoSyncLastCount,
            lastSyncAt: autoSyncLastSyncAt
        )
    }

    /// 捕获真的开始：启动灵动岛状态。
    private func noteCaptureActivityStarted() {
        guard model.state.isCapturing else { return }
        captureActivity.captureStarted(sessionID: captureSessionID, content: captureActivityContent())
    }

    /// 捕获停止 / 失败：结束灵动岛状态（不动任何聊天数据）。
    private func noteCaptureActivityStopped() {
        captureActivity.captureStopped(captureActivityContent())
    }

    /// 真的开始捕获：状态进 `capturing`，并起一个灵动岛状态。没起来就不建（不留假 Activity）。
    private func markCaptureDidStart() {
        guard model.captureDidStart() else { return }
        noteCaptureActivityStarted()
    }

    /// 捕获失败：进 `failed` 并收掉灵动岛状态（End 时带上错误文案，但不含正文 / 路径）。
    private func markCaptureDidFail(_ reason: String) {
        captureFence.invalidate()
        autoSyncState = .disabled
        let sync = autoSync
        ocrQueue.async { sync.stop() }
        model.captureDidFail(reason)
        noteCaptureActivityStopped()
    }

    /// 系统是否具备 iOS 版 ScreenCaptureKit（iOS 27+ 且 SDK 里有这个 framework）。
    static var isSystemSupported: Bool {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }

    // MARK: - 用户动作

    /// 点「开始动态识别测试」：只挂观察者并调起系统 picker，**不**提前假设捕获成功。
    func start() {
        guard model.beginStart() else { return }
        // 新的一轮 capture：用一个新的 session 标识，之后建的就是新的 Live Activity，
        // 绝不复用上一轮已经结束的那个（避免灵动岛显示上一次的状态）。
        captureSessionID = UUID().uuidString
        // 阶段 12B：重新开始 = 新 session，实时聊天与稳定化状态一起清零，避免跨会话误拼。
        chat = .empty
        sceneVerdict = .unknown
        autoSyncState = .disabled
        autoSyncLastSyncAt = nil
        autoSyncLastCount = 0
        let engine = chatEngine
        let newGeneration = model.generation
        captureFence.activate(newGeneration)
        let sync = autoSync
        ocrQueue.async {
            _ = engine.reset(generation: newGeneration)
            // 新 session：自动同步回到「关闭」，必须由用户重新主动开启
            sync.resetForNewSession(generation: newGeneration)
        }
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            let bridge = LiveContentSharingPickerBridge(owner: self)
            pickerBridge = bridge
            let picker = SCContentSharingPicker.shared
            picker.add(bridge)
            picker.isActive = true
            picker.present(using: .display)     // 引导用户从「整屏」入口选
            return
        }
        #endif
        markCaptureDidFail("当前系统不支持动态屏幕识别（需要 iOS 27 或更高）")
    }

    /// 点「停止动态识别」：停 stream、移除输出、清观察者。多次点安全。
    func stop() {
        guard model.beginStop() else { return }
        captureFence.invalidate()
        autoSyncState = .disabled
        pendingFrame = nil
        let sync = autoSync
        ocrQueue.async { sync.stop() }      // 取消排队 + 关闭开关；已共享成功的聊天不动
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            let current = stream as? SCStream
            let output = streamBridge as? LiveScreenStreamBridge
            releasePicker()
            stream = nil
            streamBridge = nil
            Task { [weak self] in
                if let current {
                    if let output { try? current.removeStreamOutput(output, type: .screen) }
                    try? await current.stopCapture()
                }
                await MainActor.run {
                    self?.model.captureDidStop()
                    self?.noteCaptureActivityStopped()   // 停止：顺手收掉灵动岛状态
                }
            }
            return
        }
        #endif
        model.captureDidStop()
        noteCaptureActivityStopped()
    }

    /// 只清阶段 12B 的实时聊天（时间线 / 稳定化 / 去重状态）。
    ///
    /// **不**停止屏幕捕获、**不**碰共享聊天、**不**碰键盘上的聊天：
    /// 捕获继续跑，之后会重新积累。
    func clearLiveChat() {
        chat = .empty
        let engine = chatEngine
        let sync = autoSync
        let generation = model.generation
        ocrQueue.async { [weak self] in
            sync.clearLiveChat()            // 只取消排队，不删已共享出去的聊天
            let snapshot = engine.reset(generation: generation)
            Task { @MainActor in self?.chat = snapshot }
        }
    }

    /// 用户主动开关「自动同步给狗头军师」。默认关闭，而且要每个 capture session 重新授权。
    func setAutoSyncEnabled(_ enabled: Bool) {
        guard model.state.isCapturing else { return }
        let sync = autoSync
        let engine = chatEngine
        ocrQueue.async {
            sync.setEnabled(enabled, messages: engine.pipeline.allowsFullRecognition ? engine.pipeline.snapshot().messages : [])
            if !engine.pipeline.allowsFullRecognition { sync.noteLeftChatScene() }
        }
    }

    // MARK: - 阶段 12C：实时聊天 → 用户确认 → 现有共享聊天

    /// 「整理当前实时聊天」：把当前时间线**冻结**成一份草稿。
    /// 捕获可以继续跑、时间线可以继续涨，这份草稿不会跟着跳。
    func beginLiveChatReview() {
        guard !chat.messages.isEmpty else { return }
        reviewDraft = LiveChatReviewDraft(timeline: chat.messages)
        reviewNote = nil
    }

    /// 放弃这次整理：只丢草稿；实时聊天与已共享聊天都不动。
    func cancelLiveChatReview() {
        reviewDraft = nil
        reviewNote = nil
    }

    func setReviewRole(id: UUID, role: LiveChatRole) {
        reviewDraft?.update(id: id, role: role)
    }

    func setReviewText(id: UUID, text: String) {
        reviewDraft?.update(id: id, text: text)
    }

    func setReviewIncluded(id: UUID, isIncluded: Bool) {
        reviewDraft?.update(id: id, isIncluded: isIncluded)
    }

    /// 「保存给狗头军师」：只有用户点才写，走的还是现有 SharedChatStore（校验 / 原子写 / 错误模型都不变）。
    func saveLiveChatReview() {
        guard let draft = reviewDraft else { return }
        let sync = autoSync
        ocrQueue.async { [weak self] in
            do {
                let snapshot = try LiveChatReviewSaver(store: SharedChatStore()).save(draft)
                sync.noteManualSaveSucceeded()
                Task { @MainActor in
                    self?.reviewNote = "已保存 \(snapshot.messages.count) 条实时聊天，点击键盘狗头即可载入。"
                }
            } catch {
                Task { @MainActor in self?.reviewNote = error.localizedDescription }
            }
        }
    }

    // MARK: - picker / stream 回调（由桥转发进来）

    func pickerDidProvideFilter(_ filter: Any) {
        guard model.pickerDidSelectContent() else { return }
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *), let contentFilter = filter as? SCContentFilter {
            let bridge = LiveScreenStreamBridge(owner: self, generation: model.generation)
            streamBridge = bridge
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = false      // 只要画面，不要麦克风 / 系统声音
            let newStream = SCStream(filter: contentFilter, configuration: configuration, delegate: bridge)
            stream = newStream
            let startedGeneration = model.generation
            Task { [weak self] in
                do {
                    try newStream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: self?.sampleQueue)
                    try await newStream.startCapture()
                    guard let self, self.model.generation == startedGeneration else {
                        try? await newStream.stopCapture(); return
                    }
                    self.markCaptureDidStart()
                } catch {
                    guard let self, self.model.generation == startedGeneration else { return }
                    self.markCaptureDidFail("启动屏幕捕获失败")
                }
            }
            return
        }
        #endif
        markCaptureDidFail("系统没有给出可用的捕获内容")
    }

    func pickerDidCancel() {
        releasePicker()
        model.pickerDidCancel()
    }

    func pickerDidFail(_ reason: String) {
        releasePicker()
        model.pickerDidFail(reason)
        noteCaptureActivityStopped()
    }

    func streamDidStopWithError(_ reason: String, generation: Int) {
        guard generation == model.generation else { return }
        stream = nil
        streamBridge = nil
        pendingFrame = nil
        captureFence.invalidate()
        let sync = autoSync
        ocrQueue.async { sync.stop() }
        model.captureDidStopWithError(reason)
        autoSyncState = .disabled
        noteCaptureActivityStopped()   // 系统结束了共享：把灵动岛状态也收掉
    }

    // MARK: - 帧 → OCR

    /// 由 stream 桥在 **sample 队列**上调用：只做便宜的校验与像素缓冲提取，主线程不碰 CMSampleBuffer。
    nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, generation: Int) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard frameDeliveryGate.acquire() else { return }
        let orientation = LiveScreenCaptureManager.frameOrientation(sampleBuffer)
        Task { @MainActor in
            defer { self.frameDeliveryGate.release() }
            guard generation == self.model.generation else { return }
            self.handleScreenFrame(pixelBuffer: pixelBuffer, orientation: orientation)
        }
    }

    private func handleScreenFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        switch model.receiveScreenFrame(at: Date()) {
        case .ignore, .throttled:
            return
        case .holdPending:
            pendingFrame = (pixelBuffer, orientation)      // 只留最新一帧
        case .runOCR:
            pendingFrame = nil
            runOCR(pixelBuffer: pixelBuffer, orientation: orientation, generation: model.generation)
        }
    }

    private func runOCR(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, generation: Int) {
        model.ocrDidStart(at: Date())
        let languages = ChatOCRService.defaultLanguageHints
        let engine = chatEngine
        let sync = autoSync
        let fence = captureFence
        ocrQueue.async { [weak self] in
            guard fence.isCurrent(generation) else { return }
            var result: Result<LiveOCRSnapshot, LiveOCRFailure>
            do {
                let evidence = try ChatSceneProbe.recognize(pixelBuffer: pixelBuffer,
                    orientation: orientation, languages: languages)
                guard fence.isCurrent(generation) else { return }
                engine.pipeline.detect(evidence)
                if engine.pipeline.startsNewSession { sync.beginChatGeneration(engine.pipeline.chatGeneration) }
                if engine.pipeline.allowsFullRecognition {
                    let snapshot = try LiveScreenOCRProcessor.recognize(pixelBuffer: pixelBuffer,
                        orientation: orientation, languages: languages)
                    guard fence.isCurrent(generation) else { return }
                    let before = engine.pipeline.chatGeneration
                    let chat = engine.pipeline.ingest(snapshot.observations, at: snapshot.timestamp)
                    if engine.pipeline.chatGeneration != before { sync.beginChatGeneration(engine.pipeline.chatGeneration) }
                    sync.noteTimeline(chat.messages, generation: engine.pipeline.chatGeneration)
                    result = .success(snapshot)
                } else {
                    sync.noteLeftChatScene()
                    result = .success(LiveOCRSnapshot(timestamp: Date(), strings: [], observations: []))
                }
            } catch {
                sync.noteLeftChatScene()
                result = .failure(LiveOCRFailure("这一帧识别失败"))
            }
            let chatSnapshot = engine.pipeline.snapshot()
            let verdict = engine.pipeline.verdict
            Task { @MainActor in
                self?.finishOCR(result, chat: chatSnapshot, verdict: verdict, generation: generation)
            }
        }
    }

    private func finishOCR(
        _ result: Result<LiveOCRSnapshot, LiveOCRFailure>,
        chat chatSnapshot: LiveChatSnapshot?,
        verdict: ChatSceneVerdict?,
        generation: Int
    ) {
        guard generation == model.generation, model.state.isCapturing else { return }
        if let chatSnapshot { chat = chatSnapshot }
        if let verdict { sceneVerdict = verdict }
        // 灵动岛 / 锁屏只要「状态 + 计数」：规划器会去重 + 节流，不会每帧都推。
        captureActivity.stateChanged(captureActivityContent())
        // 代际号对不上（已经停止 / 重新开始）时，模型一个字都不写。
        let runPending = model.ocrDidFinish(generation: generation, result: result, at: Date())
        if runPending, let pending = pendingFrame {
            pendingFrame = nil
            runOCR(pixelBuffer: pending.pixelBuffer, orientation: pending.orientation, generation: model.generation)
        }
    }

    // MARK: - 小工具

    private func releasePicker() {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            let picker = SCContentSharingPicker.shared
            if let bridge = pickerBridge as? LiveContentSharingPickerBridge { picker.remove(bridge) }
            picker.isActive = false
        }
        #endif
        pickerBridge = nil
    }

    /// 帧方向来自 ScreenCaptureKit 的帧元数据（iOS 27 的 `SCStreamFrameInfoVideoOrientation`，
    /// 取值遵循 `CGImagePropertyOrientation`）；拿不到就按正立处理，不硬编码猜测。
    private nonisolated static func frameOrientation(_ sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
               let info = attachments.first,
               let number = info[SCStreamFrameInfo.videoOrientation] as? NSNumber,
               let raw = UInt32(exactly: number.uint64Value),
               let orientation = CGImagePropertyOrientation(rawValue: raw) {
                return orientation
            }
        }
        #endif
        return .up
    }
}

#if canImport(ScreenCaptureKit)

/// 系统内容共享 picker 的回调桥：只把结果转成主线程上的方法调用，不自己保存状态。
@available(iOS 27.0, *)
private final class LiveContentSharingPickerBridge: NSObject, SCContentSharingPickerObserver {
    private weak var owner: LiveScreenCaptureManager?

    init(owner: LiveScreenCaptureManager) {
        self.owner = owner
        super.init()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak owner] in owner?.pickerDidProvideFilter(filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak owner] in owner?.pickerDidCancel() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak owner] in owner?.pickerDidFail("系统没能启动内容共享选择") }
    }
}

/// SCStream 的帧 / 停止回调桥：只在 sample 队列上做便宜校验，OCR 与状态都由管理器负责。
@available(iOS 27.0, *)
private final class LiveScreenStreamBridge: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var owner: LiveScreenCaptureManager?

    private let generation: Int

    init(owner: LiveScreenCaptureManager, generation: Int) {
        self.generation = generation
        self.owner = owner
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }      // 音频 / 其它类型一律不处理
        owner?.handleSampleBuffer(sampleBuffer, generation: generation)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let token = generation
        Task { @MainActor [weak owner] in owner?.streamDidStopWithError("屏幕共享被系统结束", generation: token) }
    }
}

#endif

/// Access confined to the serial OCR queue.
private final class LiveChatEngineBox {
    var pipeline = LiveChatScenePipeline()
    func reset(generation: Int) -> LiveChatSnapshot {
        pipeline.reset()
        return pipeline.snapshot()
    }
}

/// Stop invalidates queued/in-flight work without waiting for expensive Vision processing.
private final class LiveCaptureFence {
    private let lock = NSLock()
    private var generation: Int?
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return generation != nil }
    var currentToken: Int? { lock.lock(); defer { lock.unlock() }; return generation }
    func whileActive(_ operation: () throws -> SharedChatSnapshot) rethrows -> SharedChatSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard generation != nil else { return nil }
        return try operation()
    }
    func activate(_ token: Int) { lock.lock(); defer { lock.unlock() }; generation = token }
    func invalidate() { lock.lock(); defer { lock.unlock() }; generation = nil }
    func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == token
    }
}
