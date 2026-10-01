import Foundation
import UIKit

/// 狗头军师 iOS 键盘。纯系统控件 + Auto Layout，不联网、不读剪贴板。
///
/// 两种布局：
/// - 英文 26 键（原有实现，行为不变）
/// - 中文九键（对标 Android 稳定版布局；候选来自 GoutouPinyinTable，输入状态在 NineKeyInputEngine）
final class KeyboardViewController: UIInputViewController {

    // MARK: - 英文 26 键（照 iOS 系统键盘排）

    private enum EnglishPage { case letters, numbers, symbols }

    private let englishKeyHeight: CGFloat = 46
    private let englishSpacing: CGFloat = 6
    private let englishHeight: CGFloat = 216

    private var englishPage: EnglishPage = .letters
    private var shiftOn = false

    private let englishLetterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private let englishNumberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "￥", "&", "@", "\""],
    ]
    private let englishSymbolRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "·"],
    ]
    private let englishPunctuationRow = [".", ",", "?", "!", "'"]

    // MARK: - 布局模式（新增）

    private enum Mode: String {
        case chineseNineKey
        case englishQWERTY
    }

    private static let modeStorageKey = "goutou.keyboard.mode"
    private let nineKeyHeight: CGFloat = 302

    private var mode: Mode = .chineseNineKey
    private var page: NineKeyPage = .nineKey
    private let nineKeyEngine = NineKeyInputEngine()
    private weak var nineKeyView: NineKeyKeyboardView?

    // MARK: - 军师面板状态（新增）

    private weak var mentorPanel: GoutouPanelView?
    private var segments: [GoutouSegment] = []
    private var memory: [PersonMemory] = []
    /// 自动归纳完之后给一句提示
    private var memoryNote: String?
    /// 上一次分析的记忆筛选结果（调试用，不进主界面）
    private var lastMemorySelection: MemorySelectionResult?
    /// 6.9 记忆管理页：筛选 / 搜索词 / 正在看的那条 / 编辑草稿。
    /// 全部按 `activeProfileID` 来算——换人物就重置，绝不跨人物复用。
    private var memoryFilter: MemoryListFilter = .all
    private var memoryQuery = ""
    private var memoryDetailID: UUID?
    private var memoryEditDraft: MemoryEditDraft?
    /// 正在等二次确认的删除（删了就找不回来，所以要确认）
    private var memoryPendingDeleteID: UUID?
    /// 全部人物档案 + 当前是谁（第六阶段：一人一份上下文/记忆/总结）
    private var profiles: [GoutouPersonProfile] = []
    private var activeProfileID: UUID = GoutouProfileStore.activeProfile().id
    private var panelState: GoutouPanelState = .empty(banner: nil)
    /// 识别聊天：预览 → 使用 → 取消使用 的状态机（纯内存，不持久化，阶段 8 不接 AI）
    private var recognizedChat = RecognizedChatSession()
    /// 阶段 12E：共享聊天是否有更新（独立状态，不和 AI 分析状态混在一起）。
    private var sharedChatUpdate = SharedChatUpdateState.idle
    /// 键盘当前已经预览过或使用过的共享聊天指纹：用来判断「是不是同一份聊天」。
    private var knownSharedChatFingerprint: String?
    private var automaticChatNotice: String?
    /// 阶段 9：识别聊天分析的状态机 + 在途请求（只有用户点「分析这段聊天」才会赋值）
    private var recognizedChatAnalysis = RecognizedChatAnalysisSession()
    private var recognizedChatTask: URLSessionTask?
    /// 上一次成功的结果（失败时也留着，结果区不会空掉）
    private var lastResult: GoutouResult?
    private var panelTask: URLSessionTask?
    private var isPanelVisible = false
    private var config: GoutouConfig? = GoutouConfig.load()
    private var skillText: String = ""

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        let stored = UserDefaults.standard.string(forKey: KeyboardViewController.modeStorageKey)
        mode = Mode(rawValue: stored ?? "") ?? .chineseNineKey
        skillText = KeyboardViewController.loadSkillText()
        // 词库 400KB 左右，提前读进来，别等到第一次按键时卡一下。
        GoutouPinyinTable.shared.loadIfNeeded()
        // 上次没清掉的上下文接着用（退出面板、键盘被回收都不会丢）
        refreshProfiles()
        segments = GoutouSegmentStore.load()
        memory = GoutouMemoryRepository.getMemories(personID: activeProfileID)
        rebuildKeyboard()
    }

    /// 军师人格：直接把仓库里那份 SKILL.md 打进键盘 bundle，两边共用同一份口径。
    private static func loadSkillText() -> String {
        guard
            let url = Bundle.main.url(forResource: "GoutouSkill", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    /// 切布局：清掉 view 上的一切重建，避免两种布局互相残留。
    private func rebuildKeyboard() {
        for subview in view.subviews {
            subview.removeFromSuperview()
        }
        for constraint in view.constraints {
            view.removeConstraint(constraint)
        }
        nineKeyView = nil
        mentorPanel = nil
        nineKeyEngine.clear()
        page = .nineKey
        // segments / panelState / 正在跑的请求都不在这里清：
        // iOS 弹「允许粘贴」的确认框时，键盘的 view 有可能被重建一次，
        // 以前这样会把你刚加进去的上下文和刚出的结果一起清掉。

        switch mode {
        case .englishQWERTY:
            view.backgroundColor = GoutouTheme.englishBackground
            buildLayout()
        case .chineseNineKey:
            view.backgroundColor = GoutouTheme.background
            buildNineKeyLayout()
        }

        if isPanelVisible {
            showMentorPanel()
        }
    }

    // MARK: - 搭建界面

    private func buildLayout() {
        for subview in view.subviews {
            subview.removeFromSuperview()
        }
        for constraint in view.constraints {
            view.removeConstraint(constraint)
        }
        view.backgroundColor = GoutouTheme.englishBackground

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = englishSpacing
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: englishSpacing),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -englishSpacing),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        switch englishPage {
        case .letters:
            root.addArrangedSubview(makeEnglishRow(englishLetterRows[0], letters: true))
            root.addArrangedSubview(makeEnglishRow(englishLetterRows[1], letters: true))
            root.addArrangedSubview(makeEnglishLetterBottomKeysRow())
        case .numbers:
            for row in englishNumberRows {
                root.addArrangedSubview(makeEnglishRow(row, letters: false))
            }
            root.addArrangedSubview(makeEnglishPunctuationKeysRow(backTitle: "#+="))
        case .symbols:
            for row in englishSymbolRows {
                root.addArrangedSubview(makeEnglishRow(row, letters: false))
            }
            root.addArrangedSubview(makeEnglishPunctuationKeysRow(backTitle: "123"))
        }
        root.addArrangedSubview(makeEnglishBottomRow())

        // 键盘高度写死（和 iOS 自带键盘一致，横屏不做特殊处理）。
        let height = view.heightAnchor.constraint(equalToConstant: englishHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    /// 一行键：按权重分宽度（权重和不要求等于 1，内部按比例算）。
    private func makeEnglishRow(_ keys: [String], letters: Bool) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = englishSpacing
        row.distribution = .fill
        row.alignment = .fill
        for key in keys {
            let title = letters ? (shiftOn ? key.uppercased() : key.lowercased()) : key
            row.addArrangedSubview(makeEnglishKey(
                title: title,
                action: letters ? #selector(handleLetter(_:)) : #selector(handleLiteral(_:))
            ))
        }
        applyWeights(row, weights: Array(repeating: 1, count: keys.count))
        return row
    }

    /// 字母页第三行：⇧ + zxcvbnm + ⌫
    private func makeEnglishLetterBottomKeysRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = englishSpacing
        row.distribution = .fill
        row.alignment = .fill

        let shift = makeEnglishKey(
            title: shiftOn ? "⬆︎" : "⇧",
            action: #selector(handleShift),
            background: shiftOn ? GoutouTheme.englishKey : GoutouTheme.englishFunctionKey
        )
        shift.accessibilityLabel = shiftOn ? "关闭大写" : "大写"
        row.addArrangedSubview(shift)

        for key in englishLetterRows[2] {
            let title = shiftOn ? key.uppercased() : key.lowercased()
            row.addArrangedSubview(makeEnglishKey(title: title, action: #selector(handleLetter(_:))))
        }

        let delete = makeEnglishKey(
            title: "⌫",
            action: #selector(handleDelete),
            background: GoutouTheme.englishFunctionKey
        )
        delete.accessibilityLabel = "删除"
        row.addArrangedSubview(delete)

        applyWeights(row, weights: [1.5] + Array(repeating: 1, count: englishLetterRows[2].count) + [1.5])
        return row
    }

    /// 数字/符号页第三行：#+= 或 123 + 标点 + ⌫
    private func makeEnglishPunctuationKeysRow(backTitle: String) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = englishSpacing
        row.distribution = .fill
        row.alignment = .fill

        let back = makeEnglishKey(
            title: backTitle,
            action: #selector(handleSwitchEnglishPage),
            fontSize: 15,
            background: GoutouTheme.englishFunctionKey
        )
        back.accessibilityLabel = backTitle == "123" ? "回到数字页" : "切换到更多符号"
        row.addArrangedSubview(back)

        for key in englishPunctuationRow {
            row.addArrangedSubview(makeEnglishKey(title: key, action: #selector(handleLiteral(_:))))
        }

        let delete = makeEnglishKey(
            title: "⌫",
            action: #selector(handleDelete),
            background: GoutouTheme.englishFunctionKey
        )
        delete.accessibilityLabel = "删除"
        row.addArrangedSubview(delete)

        applyWeights(row, weights: [1.5] + Array(repeating: 1, count: englishPunctuationRow.count) + [1.5])
        return row
    }

    /// 底行：123/ABC + 🌐 + 中 + 空格 + 换行（和系统键盘一样）。
    private func makeEnglishBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = englishSpacing
        row.distribution = .fill
        row.alignment = .fill

        let pageTitle = englishPage == .letters ? "123" : "ABC"
        let pageKey = makeEnglishKey(
            title: pageTitle,
            action: #selector(handleToggleEnglishPage),
            fontSize: 16,
            background: GoutouTheme.englishFunctionKey
        )
        pageKey.accessibilityLabel = pageTitle == "123" ? "数字和符号" : "回到字母"
        row.addArrangedSubview(pageKey)

        if needsInputModeSwitchKey {
            let globe = makeEnglishKey(
                title: "🌐",
                action: #selector(handleNextKeyboard),
                fontSize: 18,
                background: GoutouTheme.englishFunctionKey
            )
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            row.addArrangedSubview(globe)
        }

        row.addArrangedSubview(makeEnglishKey(
            title: "中",
            action: #selector(handleSwitchToChinese),
            fontSize: 16,
            background: GoutouTheme.englishFunctionKey
        ))
        row.addArrangedSubview(makeEnglishKey(title: "空格", action: #selector(handleSpace), fontSize: 15))
        row.addArrangedSubview(makeEnglishKey(
            title: "换行",
            action: #selector(handleReturn),
            fontSize: 15,
            background: GoutouTheme.englishFunctionKey
        ))

        var weights: [CGFloat] = [1.5]
        if needsInputModeSwitchKey { weights.append(1.5) }
        weights.append(contentsOf: [1.5, 5, 1.5])
        applyWeights(row, weights: weights)
        return row
    }

    /// 按行内权重把宽度分下去（用一个 layout guide 扣掉间距，避免和 spacing 打架）。
    private func applyWeights(_ row: UIStackView, weights: [CGFloat]) {
        let views = row.arrangedSubviews
        guard !views.isEmpty, views.count == weights.count else { return }
        let total = weights.reduce(0, +)
        guard total > 0 else { return }

        let guide = UILayoutGuide()
        row.addLayoutGuide(guide)
        guide.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        guide.widthAnchor.constraint(
            equalTo: row.widthAnchor,
            constant: -englishSpacing * CGFloat(views.count - 1)
        ).isActive = true
        for subview in views {
            guard let index = views.firstIndex(of: subview) else { continue }
            subview.widthAnchor.constraint(
                equalTo: guide.widthAnchor,
                multiplier: weights[index] / total
            ).isActive = true
        }
    }

    private func makeEnglishKey(
        title: String,
        action: Selector,
        fontSize: CGFloat = 22,
        background: UIColor = GoutouTheme.englishKey
    ) -> NineKeyButton {
        let key = NineKeyButton(type: .system)
        key.setTitle(title, for: .normal)
        key.titleLabel?.font = .systemFont(ofSize: fontSize, weight: .regular)
        key.applyStyle(background: background, cornerRadius: 5)
        key.setTitleColor(GoutouTheme.englishText, for: .normal)
        key.pressedColor = GoutouTheme.englishKeyPressed
        key.layer.borderWidth = 0
        key.layer.masksToBounds = false
        key.layer.shadowColor = UIColor.black.cgColor
        key.layer.shadowOpacity = 0.22
        key.layer.shadowRadius = 0
        key.layer.shadowOffset = CGSize(width: 0, height: 1)
        key.addTarget(self, action: action, for: .touchUpInside)
        key.heightAnchor.constraint(equalToConstant: englishKeyHeight).isActive = true
        return key
    }

    // MARK: - 按键动作

    @objc private func handleLetter(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(text)
        if shiftOn {
            // 和系统键盘一样：大写只作用一个字母
            shiftOn = false
            buildLayout()
        }
    }

    /// 数字页 / 符号页的字符键：按下就上屏。
    @objc private func handleLiteral(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(text)
    }

    @objc private func handleShift() {
        shiftOn.toggle()
        buildLayout()
    }

    /// 字母页的「123」/ 数字页的「ABC」：字母页 ↔ 数字页。
    @objc private func handleToggleEnglishPage() {
        englishPage = englishPage == .letters ? .numbers : .letters
        buildLayout()
    }

    /// 数字页的「#+=」/ 符号页的「123」：数字页 ↔ 符号页。
    @objc private func handleSwitchEnglishPage() {
        englishPage = englishPage == .numbers ? .symbols : .numbers
        buildLayout()
    }

    @objc private func handleSpace() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func handleDelete() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func handleReturn() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func handleNextKeyboard() {
        advanceToNextInputMode()
    }

    // MARK: - 中文九键（新增）

    private func buildNineKeyLayout() {
        let keyboard = NineKeyKeyboardView(showsGlobeKey: needsInputModeSwitchKey)
        keyboard.delegate = self
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)

        let panel = GoutouPanelView()
        panel.delegate = self
        panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let height = view.heightAnchor.constraint(equalToConstant: nineKeyHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        nineKeyView = keyboard
        mentorPanel = panel
        refreshNineKeyView()
    }

    // MARK: - 军师面板（新增）

    private func showMentorPanel() {
        isPanelVisible = true
        nineKeyView?.isHidden = true
        mentorPanel?.isHidden = false
        mentorPanel?.resetScreen()
        // FINAL：狗头入口事件自动读取并采用最新的合法聊天。
        checkForSharedChatUpdate()
        refreshPanel()
    }

    /// 阶段 12E：键盘重新出现（包括被系统回收后重建）时，如果面板正开着就再检查一次。
    /// 事件触发，**不做**任何定时轮询。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isPanelVisible else { return }
        checkForSharedChatUpdate()
        refreshPanel()
    }

    private func hideMentorPanel() {
        isPanelVisible = false
        panelTask?.cancel()
        panelTask = nil
        // 阶段 9：面板收起就作废在途的分析请求；已经拿到的分析留着，不塞进记忆也不落盘。
        recognizedChatTask?.cancel()
        recognizedChatTask = nil
        recognizedChatAnalysis.cancelInFlight()
        mentorPanel?.isHidden = true
        nineKeyView?.isHidden = false
        refreshNineKeyView()
    }

    /// 换人物时把记忆管理页的状态清干净，免得看到上一个人的筛选结果
    private func resetMemoryBrowser() {
        memoryFilter = .all
        memoryQuery = ""
        memoryDetailID = nil
        memoryEditDraft = nil
        memoryPendingDeleteID = nil
    }

    private func refreshPanel() {
        // 记忆管理页要连归档的一起看，所以这里单独从 Repository 读一份完整的（很便宜）
        let now = Date()
        let allMemories = GoutouMemoryRepository.getMemories(personID: activeProfileID, includeArchived: true)
        mentorPanel?.render(GoutouPanelSnapshot(
            state: panelState,
            segments: segments,
            memory: memory,
            profiles: profiles,
            activeProfileID: activeProfileID,
            lastResult: lastResult,
            configSummary: config?.summary ?? "",
            memoryNote: memoryNote,
            memoryItems: MemoryManagement.items(
                personID: activeProfileID,
                memories: allMemories,
                filter: memoryFilter,
                query: memoryQuery,
                now: now
            ),
            memoryCounts: MemoryManagement.counts(personID: activeProfileID, memories: allMemories, now: now),
            memoryFilter: memoryFilter,
            memoryQuery: memoryQuery,
            memoryKeywords: MemoryManagement.quickKeywords(personID: activeProfileID, memories: allMemories),
            memoryDetail: memoryDetailID.flatMap {
                MemoryManagement.detail(id: $0, personID: activeProfileID, memories: allMemories, now: now)
            },
            memoryEditDraft: memoryEditDraft,
            memoryPendingDeleteID: memoryPendingDeleteID,
            sharedChat: recognizedChat.preview,
            automaticChatNotice: automaticChatNotice,
            sharedChatError: recognizedChat.errorMessage,
            activeRecognizedChat: recognizedChat.active,
            pendingSharedChat: sharedChatUpdate.pending,
            recognizedChatAnalysis: recognizedChatAnalysis.state,
            recognizedChatRewriteNotice: recognizedChatAnalysis.rewriteNotice
        ))
    }

    /// 给用户看的一句话；技术原文留给「查看详情」。
    private static func friendlyFailureSummary(_ error: GoutouAIError) -> String {
        switch error {
        case .badJSON, .badURL:
            return "分析失败，返回格式异常"
        case .reasoningOnly:
            return "分析失败：模型只回了思考，没有正文"
        case .timeout:
            return "分析失败：等太久了（超时）"
        case .network:
            return "分析失败：网络没通"
        case .http:
            return "分析失败：接口返回了错误"
        case .empty:
            return "分析失败：接口没给内容"
        case .notConfigured:
            return "还没配置 AI 接口"
        case .truncated:
            return "分析失败：模型输出被截断"
        }
    }

    /// 重新读一遍档案总表（改过档案之后调一次）。
    private func refreshProfiles() {
        let book = GoutouProfileStore.loadBook()
        profiles = book.profiles
        activeProfileID = book.activeProfileID
    }

    /// 切到另一个人物：上下文/记忆/上次总结整组换掉。
    private func selectProfile(id: UUID) {
        GoutouProfileStore.select(id: id)
        refreshProfiles()
        segments = GoutouSegmentStore.load()
        memory = GoutouMemoryRepository.getMemories(personID: activeProfileID)
        resetMemoryBrowser()
        panelTask?.cancel()
        panelTask = nil
        if let summary = GoutouProfileStore.activeProfile().summary {
            let restored = GoutouResult(headline: summary.headline, replies: summary.replies)
            lastResult = restored
            panelState = .ready(restored)
        } else {
            lastResult = nil
            panelState = .empty(banner: nil)
        }
        refreshPanel()
    }

    private func createProfile() {
        let profile = GoutouProfileStore.create(name: "人物 \(profiles.count + 1)")
        refreshProfiles()
        segments = []
        memory = []
        resetMemoryBrowser()
        lastResult = nil
        panelState = .empty(banner: "已新建「\(profile.name)」——把名字复制过来点「✏️ 改名」")
        refreshPanel()
    }

    private func deleteProfile(id: UUID) {
        GoutouProfileStore.delete(id: id)
        refreshProfiles()
        segments = GoutouSegmentStore.load()
        memory = GoutouMemoryRepository.getMemories(personID: activeProfileID)
        resetMemoryBrowser()
        if let summary = GoutouProfileStore.activeProfile().summary {
            let restored = GoutouResult(headline: summary.headline, replies: summary.replies)
            lastResult = restored
            panelState = .ready(restored)
        } else {
            lastResult = nil
            panelState = .empty(banner: nil)
        }
        refreshPanel()
    }

    /// 没有 App Group，没法在键盘里打字输入名字：拿剪贴板第一行当名字。
    private func renameProfile(id: UUID) {
        guard let text = clipboardText() else {
            panelState = .needsFullAccess("剪贴板里没读到内容。先把名字复制好再来改名（没开「允许完全访问」时读剪贴板会失败）。")
            refreshPanel()
            return
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let name = String(firstLine.trimmed.prefix(20))
        guard !name.isEmpty else {
            panelState = .empty(banner: "剪贴板第一行是空的")
            refreshPanel()
            return
        }
        GoutouProfileStore.rename(id: id, to: name)
        refreshProfiles()
        panelState = .empty(banner: "已改名为「\(name)」")
        refreshPanel()
    }

    /// 分析成功之后，把这次总结记在当前人物名下（切回来还能看到）。
    private func saveSummary(_ result: GoutouResult) {
        GoutouProfileStore.updateProfile(id: activeProfileID) { profile in
            profile.summary = GoutouSavedSummary(headline: result.headline, replies: result.replies, savedAt: Date())
        }
        refreshProfiles()
    }

    private func clipboardText() -> String? {
        let text = UIPasteboard.general.string?.trimmed
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// 剪贴板第一行（记忆管理的搜索词 / 替换内容都只用第一行）
    private func clipboardFirstLine() -> String? {
        guard let text = clipboardText() else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let value = first.trimmed
        return value.isEmpty ? nil : value
    }

    /// 背景优先读草稿（你在聊天框里打的那句），读不到再退到剪贴板。
    private func draftText() -> String? {
        let text = textDocumentProxy.documentContextBeforeInput?.trimmed
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func addSegment(_ speaker: GoutouSpeaker) {
        let content = speaker == .background ? (draftText() ?? clipboardText()) : clipboardText()
        guard let text = content, !text.isEmpty else {
            panelState = .needsFullAccess(speaker == .background
                ? "草稿和剪贴板都没读到内容。要么先打一句背景，要么复制一段再点。没开「允许完全访问」时读剪贴板会失败。"
                : "剪贴板里没读到内容。要么剪贴板是空的，要么没开「允许完全访问」。")
            refreshPanel()
            return
        }
        segments.append(GoutouSegment(speaker: speaker, text: text))
        GoutouSegmentStore.save(segments)
        panelState = .empty(banner: nil)
        refreshPanel()
    }

    /// 长期档案：把剪贴板里的一段文字当成一条记忆存下来。
    private func importMemoryFromClipboard() {
        guard let text = clipboardText() else {
            panelState = .needsFullAccess("剪贴板里没读到内容。先把「她生日 3 月 5 日」这类内容复制好，再点导入。没开「允许完全访问」时读剪贴板会失败。")
            refreshPanel()
            return
        }
        do {
            _ = try GoutouMemoryRepository.addMemory(content: text, personID: activeProfileID, sourceType: .manual)
            memory = GoutouMemoryRepository.getMemories(personID: activeProfileID)
            panelState = .empty(banner: "已记下第 \(memory.count) 条，下次分析会带上")
        } catch {
            panelState = .empty(banner: "这条没记住（内容为空或人物不存在）")
        }
        refreshPanel()
    }

    private func importConfigFromClipboard() {
        guard let text = UIPasteboard.general.string else {
            panelState = .needsFullAccess("剪贴板里没读到内容。要么先在 App 里点「复制配置」，要么没开「允许完全访问」。")
            refreshPanel()
            return
        }
        guard let parsed = GoutouConfig.parse(importText: text) else {
            panelState = .empty(banner: "剪贴板里不是配置文本（第一行应该是 \(GoutouConfig.marker)）")
            refreshPanel()
            return
        }
        parsed.save()
        config = parsed
        panelState = .empty(banner: "已导入：\(parsed.summary)")
        refreshPanel()
    }

    // MARK: - 识别聊天分析（阶段 9）

    /// 作废在途请求并清掉这份聊天已有的分析：读取新聊天、取消使用、取消分析都走这里。
    private func dropRecognizedChatAnalysis() {
        recognizedChatTask?.cancel()
        recognizedChatTask = nil
        recognizedChatAnalysis.invalidate()
    }

    /// FINAL: opening the dog entry reads validated local data and adopts new content.
    /// No analysis request can originate here; failures preserve the existing context.
    private func checkForSharedChatUpdate() {
        guard hasFullAccess else {
            // App Group 读不到就别假装发现了更新（自动检查与网络 AI 的完全访问不是一回事，这里只按能否读容器判断）
            sharedChatUpdate = .idle
            return
        }
        let previousTask = recognizedChatTask
        let loaded = SharedChatAutoLoader.load(read: { try SharedChatStore().read() },
            chat: &recognizedChat, analysis: &recognizedChatAnalysis,
            cancelPrevious: { previousTask?.cancel() })
        switch loaded {
        case .adopted(let count):
            recognizedChatTask = nil
            automaticChatNotice = "已自动载入最新聊天 · \(count) 条"
            sharedChatUpdate = .upToDate
        case .unchanged:
            automaticChatNotice = recognizedChat.active.map { "当前聊天 · \($0.messageCount) 条" }
        case .failed:
            break
        }
    }

    /// 用户主动点「分析这段聊天」才会走到这里。
    ///
    /// 准入判断全在状态机里（完全访问 / 配置 / 人格 / 有没有 Active Context / 是不是正在跑），
    /// 这里只负责把 Prompt 拼好交给现有 AI 网络层，再按代际号把结果写回去。
    /// 不碰 `segments` / `lastResult` / 记忆链路，也不插输入框。
    private func startRecognizedChatAnalysis() {
        let start = recognizedChatAnalysis.begin(
            hasFullAccess: hasFullAccess,
            config: config,
            skillAvailable: !skillText.isEmpty,
            context: recognizedChat.active
        )
        guard case .started(let generation) = start else {
            // .alreadyRunning 不会改状态；其它情况状态机已经写好了失败原因。
            refreshPanel()
            return
        }

        guard let activeContext = recognizedChat.active,
              let userMessage = RecognizedChatPrompt.userMessage(messages: activeContext.messages) else {
            recognizedChatAnalysis.complete(generation: generation, result: .failure(.noActiveContext))
            refreshPanel()
            return
        }
        guard let config = config else {
            recognizedChatAnalysis.complete(generation: generation, result: .failure(.notConfigured))
            refreshPanel()
            return
        }


        recognizedChatTask = GoutouAIClient.analyzeChat(
            config: config,
            systemPrompt: RecognizedChatPrompt.systemPrompt(skill: skillText),
            userMessage: userMessage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 代际号对不上（用户已经读了别的聊天 / 取消使用 / 收起面板）就一个字都不写。
                guard self.recognizedChatAnalysis.generation == generation else { return }
                self.recognizedChatTask = nil
                switch result {
                case .success(let fields):
                    // 宽容拆出来的字段在这里做阶段 10 的严格归一化：恰好 3 条、非空、去重、长度上限。
                    self.recognizedChatAnalysis.complete(
                        generation: generation,
                        result: RecognizedChatResult.normalized(fields)
                    )
                case .failure(let error):
                    self.recognizedChatAnalysis.complete(generation: generation, result: .failure(.ai(error)))
                }
                self.refreshPanel()
            }
        }
        refreshPanel()
    }

    private func startRecognizedChatRewrite() {
        let start = recognizedChatAnalysis.beginRewrite(hasFullAccess: hasFullAccess, config: config,
            skillAvailable: !skillText.isEmpty, context: recognizedChat.active)
        guard case .started(let generation) = start else { refreshPanel(); return }
        guard let config = config, let context = recognizedChat.active,
              case .rewriting(let accepted) = recognizedChatAnalysis.state,
              let message = RecognizedChatPrompt.rewriteUserMessage(messages: context.messages, accepted: accepted) else {
            recognizedChatAnalysis.completeRewrite(generation: generation, result: .failure(.noActiveContext))
            refreshPanel()
            return
        }
        recognizedChatTask = GoutouAIClient.analyzeChat(config: config,
            systemPrompt: RecognizedChatPrompt.rewriteSystemPrompt, userMessage: message) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.recognizedChatAnalysis.generation == generation else { return }
                self.recognizedChatTask = nil
                self.recognizedChatAnalysis.completeRewrite(generation: generation,
                    result: result.mapError { .ai($0) })
                self.refreshPanel()
            }
        }
        refreshPanel()
    }

    private func startAnalysis() {
        guard !segments.isEmpty else {
            panelState = .empty(banner: "先加至少一段上下文（点 👤对方 / 🙋我）")
            refreshPanel()
            return
        }
        guard let config = config, config.isReady else {
            panelState = .needsConfig
            refreshPanel()
            return
        }
        guard !skillText.isEmpty else {
            panelState = .failed(
                summary: "分析失败：军师人格没打进包",
                detail: "GoutouSkill.md 不在 Keyboard Extension 的 bundle 里，需要重新构建一次。"
            )
            refreshPanel()
            return
        }

        panelTask?.cancel()
        panelState = .loading
        refreshPanel()

        let systemPrompt = GoutouPrompt.systemPrompt(skill: skillText)
        // 只把「和这次聊天最相关」的 Top-K 发给模型；筛选出任何问题就退回少量高重要度记忆
        let selection = MemorySelector.select(
            personID: activeProfileID,
            chat: segments,
            task: .current,
            memories: memory
        )
        let chosen = (selection.items.isEmpty && !memory.isEmpty)
            ? MemorySelector.fallback(personID: activeProfileID, memories: memory).items
            : selection.items
        lastMemorySelection = selection
        // 近期状态标一下，免得模型把它当永久事实
        let memoryLines = chosen.map { $0.category.isStable ? $0.content : "（近期）\($0.content)" }
        let userMessage = GoutouPrompt.userMessage(
            segments: segments,
            memory: memoryLines,
            extraRequirement: GoutouPrompt.replyRequirement
        )
        let analysisPersonID = activeProfileID
        let analysisSegments = segments
        let analysisSessionID = UUID()
        panelTask = GoutouAIClient.analyze(
            config: config,
            systemPrompt: systemPrompt,
            userMessage: userMessage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.panelTask = nil
                switch result {
                case .success(let value):
                    self.lastResult = value
                    self.panelState = .ready(value)
                    self.saveSummary(value)
                    self.refreshPanel()
                    // 主分析成功之后才去归纳记忆（失败路径根本不走这里）
                    self.runMemoryExtraction(
                        personID: analysisPersonID,
                        segments: analysisSegments,
                        sessionID: analysisSessionID
                    )
                case .failure(let error):
                    self.panelState = .failed(
                        summary: KeyboardViewController.friendlyFailureSummary(error),
                        detail: error.message
                    )
                }
                self.refreshPanel()
            }
        }
    }

    // MARK: - 自动归纳记忆（第六阶段补：最近聊天 → 人物记忆）

    /// 主分析成功后才调用；任何一步失败都**不改记忆**。
    private func runMemoryExtraction(personID: UUID, segments: [GoutouSegment], sessionID: UUID) {
        guard let config = config, config.isReady, !segments.isEmpty else { return }
        memoryNote = "正在归纳这次聊天…"
        refreshPanel()
        GoutouMemoryExtractor.extract(config: config, existing: memory, segments: segments) { [weak self] candidates in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 解析失败 / 请求失败 → 记忆一个字都不动
                guard let candidates = candidates else {
                    self.memoryNote = nil
                    self.refreshPanel()
                    return
                }
                self.commitMemory(candidates, personID: personID, sessionID: sessionID, messageCount: segments.count)
            }
        }
    }

    /// 事务提交：再次确认还是这个人，再算新数组，最后一次性写回。
    private func commitMemory(
        _ candidates: [GoutouMemoryCandidate],
        personID: UUID,
        sessionID: UUID,
        messageCount: Int
    ) {
        guard personID == activeProfileID else {
            memoryNote = nil
            refreshPanel()
            return
        }
        let existing = GoutouMemoryRepository.getMemories(personID: personID, includeArchived: true)
        let applied = GoutouMemoryApplier.apply(
            candidates,
            to: existing,
            personID: personID,
            sessionID: sessionID,
            messageRange: messageCount > 0 ? 1...messageCount : nil
        )
        guard applied.changed > 0 else {
            memoryNote = "这次没有新的可记内容"
            refreshPanel()
            runMemoryMaintenanceIfNeeded(personID: personID)
            return
        }
        do {
            try GoutouMemoryRepository.replaceMemories(applied.items, personID: personID)
            memory = GoutouMemoryRepository.getMemories(personID: personID)
            memoryNote = "已从本次聊天更新 \(applied.changed) 条记忆"
            refreshPanel()
            runMemoryMaintenanceIfNeeded(personID: personID)
            return
        } catch {
            // 落盘失败：界面上的记忆保持原样，不做假承诺
            memoryNote = "记忆没写进去（人物不存在），这次不算"
        }
        refreshPanel()
    }

    /// 6.8 轻量整理：合并近义记忆、归档过期的近期状态。
    ///
    /// 全在本地算（不联网、不花 Token、没有 Timer）：每次分析成功只累加计数，
    /// 达到阈值（条数 / 次数的任一）且距上次整理够久，才真正整理一次。
    private func runMemoryMaintenanceIfNeeded(personID: UUID) {
        guard personID == activeProfileID else { return }
        guard let plan = MemoryMaintenance.noteAnalysisAndMaybeRun(personID: personID) else { return }
        memory = GoutouMemoryRepository.getMemories(personID: personID)
        lastMemorySelection = nil
        if plan.mergedGroupCount > 0 || plan.archivedCount > 0 {
            memoryNote = "顺手整理了记忆：合并 \(plan.mergedGroupCount) 组、归档 \(plan.archivedCount) 条"
        }
        refreshPanel()
    }

    private func refreshNineKeyView() {
        nineKeyView?.render(
            digits: nineKeyEngine.digitsDisplay,
            pinyinHint: nineKeyEngine.pinyinHint,
            candidates: nineKeyEngine.candidates,
            page: page
        )
    }

    /// Android `flushComposing()`：把正在拼的拼音按首候选上屏。
    private func flushComposing() {
        if let text = nineKeyEngine.flushText() {
            textDocumentProxy.insertText(text)
        }
        refreshNineKeyView()
    }

    /// Android `handleKey()` 的 iOS 版分支。
    private func handleNineKeyAction(_ action: NineKeyAction) {
        switch action {
        case .digit(let key):
            nineKeyEngine.appendDigit(key)
            refreshNineKeyView()

        case .boundary:
            nineKeyEngine.toggleBoundaryAtEnd()
            refreshNineKeyView()

        case .zero, .space:
            if nineKeyEngine.digits.isEmpty {
                textDocumentProxy.insertText(" ")
            } else {
                flushComposing()
            }

        case .literal(let text):
            flushComposing()
            textDocumentProxy.insertText(text)

        case .candidate(let word):
            nineKeyEngine.clear()
            textDocumentProxy.insertText(word)
            refreshNineKeyView()

        case .delete:
            if !nineKeyEngine.deleteBackward() {
                textDocumentProxy.deleteBackward()
            }
            refreshNineKeyView()

        case .clear:
            nineKeyEngine.clear()
            refreshNineKeyView()

        case .openMentor:
            showMentorPanel()

        case .showLetters, .showNumbers, .showSymbols:
            flushComposing()
            switch action {
            case .showNumbers: page = .numbers
            case .showSymbols: page = .symbols
            default: page = .nineKey
            }
            refreshNineKeyView()

        case .toggleMode:
            flushComposing()
            switchToMode(.englishQWERTY)

        case .returnKey:
            flushComposing()
            textDocumentProxy.insertText("\n")

        case .nextKeyboard:
            advanceToNextInputMode()
        }
    }

    private func switchToMode(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: KeyboardViewController.modeStorageKey)
        rebuildKeyboard()
    }

    @objc private func handleSwitchToChinese() {
        switchToMode(.chineseNineKey)
    }
}

// MARK: - 九键键盘回调

extension KeyboardViewController: NineKeyKeyboardViewDelegate {
    func nineKeyKeyboardView(_ view: NineKeyKeyboardView, didTrigger action: NineKeyAction) {
        handleNineKeyAction(action)
    }
}

// MARK: - 军师面板回调

extension KeyboardViewController: GoutouPanelViewDelegate {
    func goutouPanel(_ panel: GoutouPanelView, didTrigger action: GoutouPanelAction) {
        switch action {
        case .back:
            hideMentorPanel()

        case .readAppGroupProbe:
            guard hasFullAccess else {
                panel.showAppGroupDiagnostic("App Group：请先开启键盘「允许完全访问」，再读取测试。")
                break
            }
            do {
                let probe = try AppGroupDiagnostics().readProbe()
                panel.showAppGroupDiagnostic("主 App → 输入法通信成功\n写入时间：\(probe.timestamp)\n固定测试值：\(probe.value)")
            } catch {
                panel.showAppGroupDiagnostic("App Group：\(error.localizedDescription)")
            }

        case .readRecognizedChat:
            // 重新读取＝先作废旧预览和旧的活动上下文，再读文件（读失败也不会留下旧聊天当上下文）。
            dropRecognizedChatAnalysis()
            if hasFullAccess {
                recognizedChat.read { try SharedChatStore().read() }
            } else {
                recognizedChat.invalidate(withError: "没有开启键盘完全访问。请到设置开启「允许完全访问」后重试。")
            }
            // 刚读到的这份就是键盘「已经知道」的聊天的了：不再提示发现新聊天
            if let preview = recognizedChat.preview {
                knownSharedChatFingerprint = SharedChatUpdateDetector.fingerprint(of: preview)
                sharedChatUpdate = .upToDate
            }
            refreshPanel()
            panel.showSharedChatPreview()

        case .useLatestSharedChat:
            // 用户明确点了才动：先取消在跑的旧 AI 请求、作废旧分析（analysis / tone / replies），
            // 再把 Active 换成最新这份。**不**调用 AI。
            guard let pending = sharedChatUpdate.pending else { break }
            dropRecognizedChatAnalysis()
            recognizedChat.adoptActive(pending.snapshot)
            knownSharedChatFingerprint = pending.fingerprint
            sharedChatUpdate = .upToDate
            refreshPanel()

        case .useRecognizedChat:
            // 只改本地状态：不读文件、不写人物记忆、不发任何网络请求（阶段 9 才接 AI）。
            recognizedChat.usePreview()
            refreshPanel()

        case .cancelRecognizedChatUse:
            // 只取消使用：预览仍在，共享聊天文件不动；这份聊天已有的分析也一起作废。
            recognizedChat.cancelUse()
            dropRecognizedChatAnalysis()
            refreshPanel()

        case .analyzeRecognizedChat:
            // 阶段 9 唯一会发网络请求的分支。
            startRecognizedChatAnalysis()

        case .rewriteRecognizedReplies:
            startRecognizedChatRewrite()

        case .cancelRecognizedChatAnalysis:
            recognizedChatTask?.cancel()
            recognizedChatTask = nil
            recognizedChatAnalysis.cancelInFlight()
            refreshPanel()

        case .insertRecognizedReply(let reply):
            // 阶段 11：只有「当前结果里逐字有这一条」才把原文插进输入框。
            // 不重新分析、不清草稿、不加空格 / 换行、不模拟回车、不发送、不写记忆、不落盘。
            let proxy = textDocumentProxy
            RecognizedReplyInsert.perform(reply, from: recognizedChatAnalysis) { proxy.insertText($0) }

        case .importConfig:
            importConfigFromClipboard()

        case .clearConfig:
            GoutouConfig.clear()
            config = nil
            panelState = .empty(banner: "配置已清空")
            refreshPanel()

        case .addSegment(let speaker):
            addSegment(speaker)

        case .deleteSegment(let index):
            guard segments.indices.contains(index) else { break }
            segments.remove(at: index)
            GoutouSegmentStore.save(segments)
            panelState = .empty(banner: "已删掉第 \(index + 1) 段，可以重新分析")
            refreshPanel()

        case .importMemory:
            importMemoryFromClipboard()

        case .setMemoryFilter(let filter):
            memoryFilter = filter
            refreshPanel()

        case .setMemoryQuery(let query):
            memoryQuery = query.trimmed
            refreshPanel()

        case .searchMemoryFromClipboard:
            guard let word = clipboardFirstLine() else {
                panelState = .needsFullAccess("剪贴板里没读到内容。先把要搜的词复制好再点「📋 取词」（没开「允许完全访问」时读剪贴板会失败）。")
                refreshPanel()
                break
            }
            memoryQuery = word
            memoryDetailID = nil
            memoryEditDraft = nil
            refreshPanel()

        case .openMemory(let id):
            memoryDetailID = id
            memoryEditDraft = nil
            refreshPanel()

        case .closeMemoryDetail:
            memoryDetailID = nil
            memoryEditDraft = nil
            memoryPendingDeleteID = nil
            refreshPanel()

        case .requestDeleteMemory(let id):
            memoryPendingDeleteID = id
            refreshPanel()

        case .cancelDeleteMemory:
            memoryPendingDeleteID = nil
            refreshPanel()

        case .confirmDeleteMemory(let id):
            memoryPendingDeleteID = nil
            // 删完就没这条了，先把详情收起来再刷新，免得渲染一个不存在的 id
            memoryDetailID = nil
            memoryEditDraft = nil
            performMemoryAction(.delete(id), successNote: "已删掉这条记忆")

        case .archiveMemory(let id):
            performMemoryAction(.archive(id), successNote: "已归档（不参与分析，随时可以恢复）")

        case .unarchiveMemory(let id):
            performMemoryAction(.unarchive(id), successNote: "已恢复，重新参与分析")

        case .confirmMemory(let id):
            performMemoryAction(.confirm(id), successNote: "已确认仍然有效，权重恢复")

        case .beginMemoryEdit(let id):
            guard let target = GoutouMemoryRepository.getMemory(id: id, personID: activeProfileID) else { break }
            memoryDetailID = id
            memoryEditDraft = MemoryEditDraft(memory: target)
            refreshPanel()

        case .cancelMemoryEdit:
            memoryEditDraft = nil
            refreshPanel()

        case .cycleMemoryCategory:
            memoryEditDraft?.nextCategory()
            refreshPanel()

        case .cycleMemoryImportance:
            memoryEditDraft?.nextImportance()
            refreshPanel()

        case .useClipboardForMemoryContent:
            guard var draft = memoryEditDraft else { break }
            guard let word = clipboardFirstLine() else {
                panelState = .needsFullAccess("剪贴板里没读到内容。先把新内容复制好再点「用剪贴板第一行替换内容」（没开「允许完全访问」时读剪贴板会失败）。")
                refreshPanel()
                break
            }
            draft.content = word
            memoryEditDraft = draft
            refreshPanel()

        case .saveMemoryEdit(let id):
            guard let draft = memoryEditDraft else { break }
            memoryEditDraft = nil
            performMemoryAction(
                .update(id: id, content: draft.content, category: draft.category, importance: draft.importance),
                successNote: "已保存这条记忆"
            )

        case .selectProfile(let id):
            selectProfile(id: id)

        case .createProfile:
            createProfile()

        case .deleteProfile(let id):
            deleteProfile(id: id)

        case .renameProfile(let id):
            renameProfile(id: id)

        case .analyze:
            startAnalysis()

        case .cancel:
            panelTask?.cancel()
            panelTask = nil
            panelState = .empty(banner: "已取消")
            refreshPanel()

        case .clearSegments:
            segments = []
            GoutouSegmentStore.clear()
            panelState = .empty(banner: nil)
            refreshPanel()

        case .copyFullAccessSteps:
            UIPasteboard.general.string = GoutouPanelView.fullAccessSteps
            panelState = .empty(banner: "已复制。照着走一遍：\(GoutouPanelView.fullAccessSteps)")
            refreshPanel()

        case .insertReply(let text):
            textDocumentProxy.insertText(text)
            hideMentorPanel()
        }
    }

    /// 记忆管理的写操作：一律走 Repository（personID 校验在那一层），
    /// 失败就一个字都不改，并且提示用的是人话。
    private func performMemoryAction(_ action: MemoryManagement.Action, successNote: String) {
        do {
            _ = try MemoryManagement.apply(action, personID: activeProfileID)
            memory = GoutouMemoryRepository.getMemories(personID: activeProfileID)
            memoryNote = successNote
        } catch MemoryRepositoryError.personMismatch {
            memoryNote = "这条记忆不属于当前人物，已拒绝"
        } catch MemoryRepositoryError.emptyContent {
            memoryNote = "内容不能为空"
        } catch {
            memoryNote = "这次没改成（记忆可能已经不在了）"
        }
        // 记忆变了：上一轮的筛选结果和缓存都不能再复用
        lastMemorySelection = nil
        refreshPanel()
    }
}
