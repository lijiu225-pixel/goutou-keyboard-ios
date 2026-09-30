import Foundation

/// 阶段 12A：动态屏幕识别的状态。一个状态一个值，不用一堆互相矛盾的 Bool。
enum LiveScreenCaptureState: Equatable {
    /// 系统版本不够（低于 iOS 27），旧功能不受影响
    case unsupported
    case idle
    /// 已经调起系统内容共享 picker，等用户选
    case presentingPicker
    /// 拿到 filter，正在建 stream / startCapture
    case starting
    case capturing
    case stopping
    case stopped
    /// 失败原因：给人看的短句，不含路径与内部对象
    case failed(String)

    var title: String {
        switch self {
        case .unsupported: return "当前系统不支持（需要 iOS 27 或更高）"
        case .idle: return "未开始"
        case .presentingPicker: return "等待系统选择要共享的内容…"
        case .starting: return "正在启动捕获…"
        case .capturing: return "正在捕获"
        case .stopping: return "正在停止…"
        case .stopped: return "已停止"
        case .failed(let reason): return "失败：\(reason)"
        }
    }

    /// 只有这些状态才允许点「开始」——避免重复建第二条 stream。
    var canStart: Bool {
        switch self {
        case .idle, .stopped, .failed: return true
        default: return false
        }
    }

    var canStop: Bool {
        switch self {
        case .presentingPicker, .starting, .capturing: return true
        default: return false
        }
    }

    var isCapturing: Bool { self == .capturing }
}

/// 阶段 12A 的全部阈值：集中定义，方便测试。
enum LiveScreenCaptureTuning {
    /// 最多每 0.8 秒跑一次 OCR（屏幕可能是 60/120 fps，绝不每帧都跑）。
    static let ocrMinimumInterval: TimeInterval = 0.8
    /// OCR 期间只保留**最新**一帧，不排队、不堆积。
    static let maximumPendingFrames = 1
    /// 屏幕文字识别语言，与截图 OCR 的 `ChatOCRService.defaultLanguageHints` 保持一致。
    static let recognitionLanguages = ["zh-Hans", "en-US"]
}

/// 收到一帧屏幕画面后的处理决定。
enum LiveFrameDecision: Equatable {
    /// 没在捕获：只计数，不动别的
    case ignore
    /// 节流窗口内：丢掉
    case throttled
    /// OCR 正在跑：留作最新待处理帧
    case holdPending
    /// 现在就跑 OCR
    case runOCR
}

/// 阶段 12A 的纯逻辑核心：状态转换、计数、节流、单 OCR in-flight、只留最新待处理帧。
///
/// 不 import ScreenCaptureKit / UIKit / Vision，所以能在 CI 上直接跑单测；
/// 真正的 picker / stream / Vision 由 `LiveScreenCaptureManager` 和 `LiveScreenOCRProcessor` 负责。
struct LiveScreenCaptureModel: Equatable {
    private(set) var state: LiveScreenCaptureState
    private(set) var framesReceived = 0
    private(set) var ocrRuns = 0
    private(set) var droppedFrames = 0
    private(set) var ocrFailures = 0
    private(set) var lastFrameAt: Date?
    private(set) var lastOCRStartedAt: Date?
    private(set) var lastOCRFinishedAt: Date?
    private(set) var lastErrorReason: String?
    /// 永远只留最近一次成功的结果，不累积历史。
    private(set) var snapshot: LiveOCRSnapshot?
    /// 每次开始 / 停止 / 失败都 +1：迟到的 OCR 结果靠它作废。
    private(set) var generation = 0
    private(set) var isOCRInFlight = false
    private(set) var hasPendingFrame = false

    init(isSupported: Bool = true) {
        state = isSupported ? .idle : .unsupported
    }

    // MARK: - 用户动作

    /// 点「开始动态识别测试」：只有 idle / stopped / failed 允许，并进入等待 picker。
    mutating func beginStart() -> Bool {
        guard state.canStart else { return false }
        generation += 1
        framesReceived = 0
        ocrRuns = 0
        droppedFrames = 0
        ocrFailures = 0
        lastFrameAt = nil
        lastOCRStartedAt = nil
        lastOCRFinishedAt = nil
        lastErrorReason = nil
        snapshot = nil
        isOCRInFlight = false
        hasPendingFrame = false
        state = .presentingPicker
        return true
    }

    /// 用户在系统 picker 里选好了内容（拿到 filter）。
    mutating func pickerDidSelectContent() -> Bool {
        guard state == .presentingPicker else { return false }
        state = .starting
        return true
    }

    mutating func pickerDidCancel() {
        guard state == .presentingPicker || state == .starting else { return }
        state = .idle
    }

    mutating func pickerDidFail(_ reason: String) {
        fail(reason)
    }

    mutating func captureDidStart() -> Bool {
        guard state == .starting || state == .capturing else { return false }
        state = .capturing
        return true
    }

    mutating func captureDidFail(_ reason: String) {
        fail(reason)
    }

    /// 点「停止动态识别」：只有正在捕获的链路才需要停。
    mutating func beginStop() -> Bool {
        guard state.canStop else { return false }
        state = .stopping
        generation += 1
        isOCRInFlight = false
        hasPendingFrame = false
        return true
    }

    /// 停止完成。多次调用安全。
    mutating func captureDidStop() {
        switch state {
        case .stopping, .starting, .presentingPicker, .capturing:
            state = .stopped
        case .unsupported, .idle, .stopped, .failed:
            break
        }
    }

    /// stream 自己断了（系统终止等）：进 failed，但允许重新开始。
    mutating func captureDidStopWithError(_ reason: String) {
        fail(reason)
    }

    // MARK: - 帧与 OCR

    /// 收到一帧 `.screen` 画面。
    mutating func receiveScreenFrame(at now: Date) -> LiveFrameDecision {
        framesReceived += 1
        lastFrameAt = now
        guard state == .capturing else { return .ignore }
        guard !isOCRInFlight else {
            hasPendingFrame = true      // 只留最新一帧
            return .holdPending
        }
        guard canStartOCR(at: now) else {
            droppedFrames += 1
            return .throttled
        }
        return .runOCR
    }

    mutating func ocrDidStart(at now: Date) {
        isOCRInFlight = true
        ocrRuns += 1
        lastOCRStartedAt = now
    }

    /// OCR 回来了。代际号对不上（已经停止或重新开始）就整个丢掉，绝不写回。
    ///
    /// 返回 true 表示「还有最新一帧在等着，而且节流允许」——调用方应当立刻再跑一次它。
    mutating func ocrDidFinish(
        generation: Int,
        result: Result<LiveOCRSnapshot, String>,
        at now: Date
    ) -> Bool {
        guard generation == self.generation else { return false }
        isOCRInFlight = false
        lastOCRFinishedAt = now
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot      // 新结果直接替换旧的，不累积
        case .failure(let reason):
            // OCR 失败不停 stream：记一笔，后续帧继续。
            ocrFailures += 1
            lastErrorReason = reason
        }
        guard hasPendingFrame else { return false }
        hasPendingFrame = false
        if canStartOCR(at: now) { return true }
        droppedFrames += 1
        return false
    }

    /// 节流窗口过了没（还没有过一次 OCR 就直接放行）。
    func canStartOCR(at now: Date) -> Bool {
        guard let last = lastOCRStartedAt else { return true }
        return now.timeIntervalSince(last) >= LiveScreenCaptureTuning.ocrMinimumInterval
    }

    private mutating func fail(_ reason: String) {
        generation += 1
        isOCRInFlight = false
        hasPendingFrame = false
        lastErrorReason = reason
        state = .failed(reason)
    }
}
