import XCTest
import UIKit

final class PanelTests: XCTestCase {
    @MainActor
    func testFinalAutomaticContextShowsAnalysisWithoutPreviewOrUse() throws {
        let messages = [GoutouChatClipboardMessage(role: .other, text: "合成消息")]
        var snapshot = GoutouPanelSnapshot(state: .empty(banner: nil), segments: [], memory: [],
            profiles: [], activeProfileID: UUID(), lastResult: nil, configSummary: "", memoryNote: nil)
        snapshot.activeRecognizedChat = RecognizedChatContext(messages: messages, updatedAt: Date())
        snapshot.automaticChatNotice = "已自动载入最新聊天 · 1 条"
        let panel = GoutouPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 302))
        let recorder = PanelActionRecorder()
        panel.delegate = recorder
        panel.render(snapshot)
        XCTAssertTrue(recorder.actions.isEmpty, "Rendering automatic context cannot request AI")
        let titles = descendants(panel).compactMap { ($0 as? UIButton)?.title(for: .normal) }
        XCTAssertTrue(titles.contains("分析这段聊天"))
        XCTAssertFalse(titles.contains("使用这份聊天"))
        XCTAssertFalse(titles.contains("使用最新聊天"))
        try tap("分析这段聊天", in: panel)
        XCTAssertEqual(recorder.actions.count, 1)
        XCTAssertTrue(recorder.actions.contains { if case .analyzeRecognizedChat = $0 { return true }; return false })
    }

    func testPaginationPreservesEveryCharacter() {
        let samples = [String(repeating: "合成测试", count: 4106),
                       String(repeating: "行\n", count: 900),
                       String(repeating: "👨‍👩‍👧‍👦e\u{301}\r\n", count: 600), "", "短句"]
        for text in samples {
            let pages = GoutouTextPagination.pages(text)
            XCTAssertEqual(pages.joined(), text)
            XCTAssertTrue(pages.allSatisfy { $0.count <= 600 })
            XCTAssertTrue(pages.allSatisfy { $0.filter { $0 == "\n" || $0 == "\r\n" }.count <= 18 })
        }
    }

    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    private func tap(_ prefix: String, in panel: GoutouPanelView) throws {
        let button = try XCTUnwrap(descendants(panel).compactMap { $0 as? UIButton }.first {
            $0.isEnabled && ($0.title(for: .normal) ?? "").hasPrefix(prefix)
        })
        button.sendActions(for: .touchUpInside)
        panel.setNeedsLayout()
        panel.layoutIfNeeded()
    }

    @MainActor
    private func assertBounded(_ panel: GoutouPanelView, file: StaticString = #filePath, line: UInt = #line) {
        let labels = descendants(panel).compactMap { $0 as? UILabel }
        XCTAssertTrue(labels.allSatisfy { ($0.text ?? "").count < 800 }, "No full long paragraph in one UILabel", file: file, line: line)
        XCTAssertTrue(labels.allSatisfy { $0.bounds.height < 1800 }, "No giant text backing layer", file: file, line: line)
        XCTAssertEqual(panel.bounds.height, 302, file: file, line: line)
    }

    @MainActor
    func testLongContextNavigationAndSharedPreview() throws {
        // Synthetic content only: 17 segments, 16422 total characters, one 15974-character segment.
        let large = String(repeating: "合成上下文", count: 3200).prefix(15974)
        let segments = [GoutouSegment(speaker: .opponent, text: String(large))]
            + (0..<16).map { _ in GoutouSegment(speaker: .me, text: String(repeating: "测", count: 28)) }
        XCTAssertEqual(segments.reduce(0) { $0 + $1.text.count }, 16422)
        let profile = GoutouPersonProfile(name: "合成测试", segments: segments)
        var snapshot = GoutouPanelSnapshot(state: .empty(banner: nil), segments: segments, memory: [],
            profiles: [profile], activeProfileID: profile.id, lastResult: nil, configSummary: "", memoryNote: nil)
        let panel = GoutouPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 302))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(panel)
        defer { window.isHidden = true }
        panel.render(snapshot)
        panel.layoutIfNeeded()

        // Reproduce the old layout mechanism without allocating its enormous rendered bitmap.
        let oldLabel = UILabel()
        oldLabel.font = .systemFont(ofSize: 13)
        oldLabel.numberOfLines = 0
        oldLabel.text = String(large)
        XCTAssertGreaterThan(oldLabel.sizeThatFits(CGSize(width: 330, height: CGFloat.greatestFiniteMagnitude)).height, 5000)

        for _ in 0..<12 {
            try tap("上下文 17 段", in: panel)
            assertBounded(panel)
            try tap("查看第 1 段全文", in: panel)
            assertBounded(panel)
            try tap("下一页", in: panel)
            assertBounded(panel)
            try tap("上一页", in: panel)
            try tap("返回上下文明细", in: panel)
            for _ in 0..<4 { try tap("下一页", in: panel); assertBounded(panel) }
            try tap("上下文 17 段", in: panel)
        }
        snapshot.sharedChat = SharedChatSnapshot(messages: (0..<9).map {
            GoutouChatClipboardMessage(role: $0 % 2 == 0 ? .me : .other, text: "合成消息\($0)")
        }, updatedAt: Date())
        panel.render(snapshot)
        panel.showSharedChatPreview()
        panel.layoutIfNeeded()
        assertBounded(panel)
        XCTAssertEqual(descendants(panel).compactMap { $0 as? UILabel }.filter { ($0.text ?? "").contains("合成消息") }.count, 9)
        XCTAssertTrue(descendants(panel).compactMap { $0 as? UIButton }.contains { ($0.title(for: .normal) ?? "").contains("上下文 17 段 · 16422 字") })
        // Failed read clears all previously displayed shared messages.
        snapshot.sharedChat = nil
        snapshot.sharedChatError = "尚未保存聊天"
        panel.render(snapshot)
        XCTAssertFalse(descendants(panel).compactMap { $0 as? UILabel }.contains { ($0.text ?? "").contains("合成消息") })
        XCTAssertEqual(snapshot.segments, segments)
    }

    /// 只记录面板发出的动作；面板本身不发网络请求，所以「使用这份聊天」只会走这一条回调。
    private final class PanelActionRecorder: GoutouPanelViewDelegate {
        private(set) var actions: [GoutouPanelAction] = []
        func goutouPanel(_ panel: GoutouPanelView, didTrigger action: GoutouPanelAction) {
            actions.append(action)
        }
    }

    /// 阶段 8：面板必须把「读到了」和「正在使用」画成两个能分辨的状态，
    /// 点「使用这份聊天」只发一个动作（不顺手触发分析）。
    @MainActor
    func testSharedChatPreviewRequiresExplicitUse() throws {
        let messages = (0..<8).map { GoutouChatClipboardMessage(role: $0 % 2 == 0 ? .me : .other, text: "合成消息\($0)") }
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = GoutouPanelSnapshot(state: .empty(banner: nil), segments: [], memory: [], profiles: [],
            activeProfileID: UUID(), lastResult: nil, configSummary: "", memoryNote: nil)
        snapshot.sharedChat = SharedChatSnapshot(messages: messages, updatedAt: savedAt)

        let panel = GoutouPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 302))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(panel)
        defer { window.isHidden = true }
        let recorder = PanelActionRecorder()
        panel.delegate = recorder

        panel.render(snapshot)
        panel.showSharedChatPreview()
        panel.layoutIfNeeded()
        assertBounded(panel)

        // B：读到了，但还没使用
        XCTAssertTrue(labels(in: panel).contains("已读取 8 条聊天"))
        XCTAssertFalse(labels(in: panel).contains { $0.hasPrefix("已使用识别聊天") })
        XCTAssertTrue(titles(in: panel).contains { $0.hasPrefix("使用这份聊天") })
        XCTAssertFalse(titles(in: panel).contains { $0.contains("取消使用识别聊天") })
        XCTAssertEqual(labels(in: panel).filter { $0.contains("合成消息") }.count, 8)

        // 点「使用这份聊天」：只发一个动作，阶段 8 不接 AI
        try tap("使用这份聊天", in: panel)
        XCTAssertEqual(recorder.actions.count, 1)
        XCTAssertTrue(recorder.actions.contains { if case .useRecognizedChat = $0 { return true }; return false })
        XCTAssertFalse(recorder.actions.contains { if case .analyze = $0 { return true }; return false })

        // C：正在使用
        snapshot.activeRecognizedChat = RecognizedChatContext(messages: messages, updatedAt: savedAt)
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains("已使用识别聊天 · 8 条"))
        XCTAssertTrue(titles(in: panel).contains { $0.contains("取消使用识别聊天") })
        XCTAssertFalse(titles(in: panel).contains { $0.hasPrefix("使用这份聊天") })
        XCTAssertEqual(labels(in: panel).filter { $0.contains("合成消息") }.count, 8)
        assertBounded(panel)

        // 再点一次：只发取消动作；预览还在，只是回到 B
        try tap("取消使用识别聊天", in: panel)
        XCTAssertTrue(recorder.actions.contains { if case .cancelRecognizedChatUse = $0 { return true }; return false })
        snapshot.activeRecognizedChat = nil
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains("已读取 8 条聊天"))
        XCTAssertEqual(labels(in: panel).filter { $0.contains("合成消息") }.count, 8)
        assertBounded(panel)
    }

    /// 阶段 9：只有点「分析这段聊天」才会发出分析动作——读取和使用都不发；
    /// 分析区只画一份分析，不出现推荐回复，也不出现插入按钮。
    @MainActor
    func testRecognizedChatAnalysisNeedsExplicitTap() throws {
        let messages = (0..<4).map { GoutouChatClipboardMessage(role: $0 % 2 == 0 ? .me : .other, text: "合成消息\($0)") }
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = GoutouPanelSnapshot(state: .empty(banner: nil), segments: [], memory: [], profiles: [],
            activeProfileID: UUID(), lastResult: nil, configSummary: "", memoryNote: nil)
        snapshot.sharedChat = SharedChatSnapshot(messages: messages, updatedAt: savedAt)
        snapshot.activeRecognizedChat = RecognizedChatContext(messages: messages, updatedAt: savedAt)

        let panel = GoutouPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 302))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(panel)
        defer { window.isHidden = true }
        let recorder = PanelActionRecorder()
        panel.delegate = recorder

        panel.render(snapshot)
        panel.showSharedChatPreview()
        panel.layoutIfNeeded()

        // idle：有入口，但还没有任何分析内容
        XCTAssertTrue(labels(in: panel).contains("【聊天分析】"))
        XCTAssertTrue(titles(in: panel).contains { $0.hasPrefix("分析这段聊天") })

        // 「读取识别聊天」只发读取动作，不发分析
        try tap("读取识别聊天", in: panel)
        XCTAssertEqual(recorder.actions.count, 1)
        XCTAssertTrue(recorder.actions.contains { if case .readRecognizedChat = $0 { return true }; return false })
        XCTAssertFalse(recorder.actions.contains { if case .analyzeRecognizedChat = $0 { return true }; return false })
        XCTAssertFalse(recorder.actions.contains { if case .analyze = $0 { return true }; return false })

        // 「分析这段聊天」只发一个分析动作
        try tap("分析这段聊天", in: panel)
        XCTAssertEqual(recorder.actions.count, 2)
        XCTAssertTrue(recorder.actions.contains { if case .analyzeRecognizedChat = $0 { return true }; return false })

        // loading：写清正在分析，按钮换成取消分析，不能再点第二次
        snapshot.recognizedChatAnalysis = .loading
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains { $0.hasPrefix("正在分析") })
        XCTAssertTrue(titles(in: panel).contains { $0.hasPrefix("取消分析") })
        XCTAssertFalse(titles(in: panel).contains { $0.hasPrefix("分析这段聊天") })
        assertBounded(panel)

        // success：分析 / 对方状态 / 恰好三条候选卡片，且没有「发送」「插入」
        let result = RecognizedChatResult(
            analysis: "对方在确认今晚的安排。",
            tone: "轻松、在推进",
            replies: ["好啊，七点老地方", "你先定地方，我都行", "行，那我请客"]
        )
        snapshot.recognizedChatAnalysis = .success(result)
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains("【聊天分析】"))
        XCTAssertTrue(labels(in: panel).contains("【对方状态】"))
        XCTAssertTrue(labels(in: panel).contains("【推荐回复】"))
        XCTAssertTrue(labels(in: panel).contains("对方在确认今晚的安排。"))
        XCTAssertTrue(labels(in: panel).contains("轻松、在推进"))
        XCTAssertTrue(labels(in: panel).contains("① 好啊，七点老地方"))
        XCTAssertTrue(labels(in: panel).contains("② 你先定地方，我都行"))
        XCTAssertTrue(labels(in: panel).contains("③ 行，那我请客"))
        let replyMarks = ["①", "②", "③"]
        let replyCards = labels(in: panel).filter { label in replyMarks.contains(where: label.hasPrefix) }
        XCTAssertEqual(replyCards.count, 3)
        XCTAssertTrue(titles(in: panel).contains { $0.hasPrefix("重新分析") })
        XCTAssertFalse(titles(in: panel).contains { $0.contains("插入") })
        XCTAssertFalse(titles(in: panel).contains { $0.contains("发送") })
        XCTAssertFalse(labels(in: panel).contains { $0.contains("发送") })
        XCTAssertFalse(labels(in: panel).contains { $0.contains("插入") })
        // 候选卡片只是展示：渲染完不该多出任何面板动作
        XCTAssertEqual(recorder.actions.count, 2)
        assertBounded(panel)

        // failure：给一个人能看懂的原因
        snapshot.recognizedChatAnalysis = .failure(.ai(.timeout))
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains { $0.contains("超时") })
        assertBounded(panel)
    }

    /// 阶段 11：三张候选卡片可点击，点第 N 条只发一个「插入第 N 条原文」的动作，
    /// 序号只属于标题；idle / loading / failure 下根本没有卡片可点。
    @MainActor
    func testRecognizedChatReplyCardsInsertExactText() throws {
        let messages = (0..<4).map { GoutouChatClipboardMessage(role: $0 % 2 == 0 ? .me : .other, text: "合成消息\($0)") }
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let replies = ["好啊，七点老地方", "你先定地方，我都行", "行，那我请客"]
        var snapshot = GoutouPanelSnapshot(state: .empty(banner: nil), segments: [], memory: [], profiles: [],
            activeProfileID: UUID(), lastResult: nil, configSummary: "", memoryNote: nil)
        snapshot.sharedChat = SharedChatSnapshot(messages: messages, updatedAt: savedAt)
        snapshot.activeRecognizedChat = RecognizedChatContext(messages: messages, updatedAt: savedAt)

        let panel = GoutouPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 302))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(panel)
        defer { window.isHidden = true }

        func replyCards() -> [UIButton] {
            let marks = ["①", "②", "③"]
            return descendants(panel).compactMap { $0 as? UIButton }.filter { button in
                marks.contains(where: (button.title(for: .normal) ?? "").hasPrefix)
            }
        }
        func tapAndCapture(_ prefix: String) throws -> [GoutouPanelAction] {
            let fresh = PanelActionRecorder()
            panel.delegate = fresh
            try tap(prefix, in: panel)
            return fresh.actions
        }
        func insertedText(_ actions: [GoutouPanelAction]) -> String? {
            for action in actions {
                if case .insertRecognizedReply(let text) = action { return text }
            }
            return nil
        }
        func firesAnalysis(_ actions: [GoutouPanelAction]) -> Bool {
            actions.contains { action in
                switch action {
                case .analyze, .analyzeRecognizedChat: return true
                default: return false
                }
            }
        }

        panel.render(snapshot)
        panel.showSharedChatPreview()
        panel.layoutIfNeeded()

        // idle / loading / failure：没有可点的候选卡片
        XCTAssertTrue(replyCards().isEmpty)
        snapshot.recognizedChatAnalysis = .loading
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(replyCards().isEmpty)
        snapshot.recognizedChatAnalysis = .failure(.ai(.timeout))
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(replyCards().isEmpty)

        // success：恰好三张可点卡片
        snapshot.recognizedChatAnalysis = .success(
            RecognizedChatResult(analysis: "对方在确认晚上。", tone: "轻松", replies: replies)
        )
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertEqual(replyCards().count, 3)
        XCTAssertTrue(replyCards().allSatisfy { $0.isEnabled })

        // 点第 1 条：只发一个插入动作，文本是原文（不带序号），也不触发分析
        let first = try tapAndCapture("① ")
        XCTAssertEqual(first.count, 1, "点一次只发一个面板动作")
        XCTAssertEqual(insertedText(first), replies[0], "第 1 条映射 replies[0]")
        XCTAssertFalse(firesAnalysis(first), "点候选不得触发分析")

        XCTAssertEqual(insertedText(try tapAndCapture("② ")), replies[1], "第 2 条映射 replies[1]")
        XCTAssertEqual(insertedText(try tapAndCapture("③ ")), replies[2], "第 3 条映射 replies[2]")
        XCTAssertEqual(insertedText(try tapAndCapture("① ")), replies[0], "再次主动点同一条仍然插入同一条")

        // 界面里仍然没有「发送」
        XCTAssertFalse(titles(in: panel).contains { $0.contains("发送") })
        XCTAssertFalse(labels(in: panel).contains { $0.contains("发送") })
        assertBounded(panel)
    }

    /// 阶段 12E：发现共享聊天更新时只出现横幅与「使用最新聊天」，
    /// 点它只发一个动作，且不会顺带触发分析。
    @MainActor
    func testPendingSharedChatBannerRequiresExplicitUse() throws {
        let messages = [GoutouChatClipboardMessage(role: .other, text: "今晚有空吗"),
                        GoutouChatClipboardMessage(role: .me, text: "有啊")]
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = GoutouPanelSnapshot(state: .empty(banner: nil), segments: [], memory: [], profiles: [],
            activeProfileID: UUID(), lastResult: nil, configSummary: "", memoryNote: nil)
        snapshot.pendingSharedChat = PendingSharedChatUpdate(
            snapshot: SharedChatSnapshot(messages: messages, updatedAt: savedAt),
            fingerprint: "test-fingerprint"
        )

        let panel = GoutouPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 302))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(panel)
        defer { window.isHidden = true }
        let recorder = PanelActionRecorder()
        panel.delegate = recorder

        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains("发现新聊天 · 2 条"))
        XCTAssertTrue(labels(in: panel).contains { $0.hasPrefix("保存时间：") })
        XCTAssertTrue(titles(in: panel).contains { $0.hasPrefix("使用最新聊天") })
        // 还没有 Active Context：不提示「使用后会替换当前聊天」
        XCTAssertFalse(labels(in: panel).contains("使用后会替换当前聊天。"))
        assertBounded(panel)

        let useLatest = try XCTUnwrap(descendants(panel).compactMap { $0 as? UIButton }.first {
            $0.isEnabled && ($0.title(for: .normal) ?? "").hasPrefix("使用最新聊天")
        })
        useLatest.sendActions(for: .touchUpInside)
        XCTAssertEqual(recorder.actions.count, 1)
        XCTAssertTrue(recorder.actions.contains { if case .useLatestSharedChat = $0 { return true }; return false })
        XCTAssertFalse(recorder.actions.contains { if case .analyze = $0 { return true }; return false })
        XCTAssertFalse(recorder.actions.contains { if case .analyzeRecognizedChat = $0 { return true }; return false })

        // 已经有 Active Context：补一句「会被替换」，但仍然只是提示
        snapshot.activeRecognizedChat = RecognizedChatContext(messages: messages, updatedAt: savedAt)
        panel.render(snapshot)
        panel.layoutIfNeeded()
        XCTAssertTrue(labels(in: panel).contains("使用后会替换当前聊天。"))
        XCTAssertEqual(recorder.actions.count, 1, "重画界面不该产生新动作")
        assertBounded(panel)
    }

    @MainActor
    private func labels(in panel: GoutouPanelView) -> [String] {
        descendants(panel).compactMap { ($0 as? UILabel)?.text }
    }

    @MainActor
    private func titles(in panel: GoutouPanelView) -> [String] {
        descendants(panel).compactMap { ($0 as? UIButton)?.title(for: .normal) }
    }
}
