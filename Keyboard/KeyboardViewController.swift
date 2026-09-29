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
    private var memory: [GoutouMemoryItem] = []
    /// 自动归纳完之后给一句提示
    private var memoryNote: String?
    /// 全部人物档案 + 当前是谁（第六阶段：一人一份上下文/记忆/总结）
    private var profiles: [GoutouPersonProfile] = []
    private var activeProfileID: String = ""
    private var panelState: GoutouPanelState = .empty(banner: nil)
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
        memory = GoutouMemoryStore.load()
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
        refreshPanel()
    }

    private func hideMentorPanel() {
        isPanelVisible = false
        panelTask?.cancel()
        panelTask = nil
        mentorPanel?.isHidden = true
        nineKeyView?.isHidden = false
        refreshNineKeyView()
    }

    private func refreshPanel() {
        mentorPanel?.render(GoutouPanelSnapshot(
            state: panelState,
            segments: segments,
            memory: memory,
            profiles: profiles,
            activeProfileID: activeProfileID,
            lastResult: lastResult,
            configSummary: config?.summary ?? "",
            memoryNote: memoryNote
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
        }
    }

    /// 重新读一遍档案总表（改过档案之后调一次）。
    private func refreshProfiles() {
        let book = GoutouProfileStore.loadBook()
        profiles = book.profiles
        activeProfileID = book.activeProfileID
    }

    /// 切到另一个人物：上下文/记忆/上次总结整组换掉。
    private func selectProfile(id: String) {
        GoutouProfileStore.select(id: id)
        refreshProfiles()
        segments = GoutouSegmentStore.load()
        memory = GoutouMemoryStore.load()
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
        lastResult = nil
        panelState = .empty(banner: "已新建「\(profile.name)」——把名字复制过来点「✏️ 改名」")
        refreshPanel()
    }

    private func deleteProfile(id: String) {
        GoutouProfileStore.delete(id: id)
        refreshProfiles()
        segments = GoutouSegmentStore.load()
        memory = GoutouMemoryStore.load()
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
    private func renameProfile(id: String) {
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
        GoutouProfileStore.updateActive { profile in
            profile.summary = GoutouSavedSummary(headline: result.headline, replies: result.replies, savedAt: Date())
        }
        refreshProfiles()
    }

    private func clipboardText() -> String? {
        let text = UIPasteboard.general.string?.trimmed
        return (text?.isEmpty ?? true) ? nil : text
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
        GoutouMemoryStore.append(text)
        memory = GoutouMemoryStore.load()
        panelState = .empty(banner: "已记下第 \(memory.count) 条，下次分析会带上")
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
        // 近期状态标一下，免得模型把它当永久事实
        let memoryLines = memory.map { $0.category.isStable ? $0.content : "（近期）\($0.content)" }
        let userMessage = GoutouPrompt.userMessage(segments: segments, memory: memoryLines)
        let analysisPersonID = activeProfileID
        let analysisSegments = segments
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
                    self.runMemoryExtraction(personID: analysisPersonID, segments: analysisSegments)
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
    private func runMemoryExtraction(personID: String, segments: [GoutouSegment]) {
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
                self.commitMemory(candidates, personID: personID)
            }
        }
    }

    /// 事务提交：再次确认还是这个人，再算新数组，最后一次性写回。
    private func commitMemory(_ candidates: [GoutouMemoryCandidate], personID: String) {
        guard personID == activeProfileID else {
            memoryNote = nil
            refreshPanel()
            return
        }
        let existing = GoutouMemoryStore.load()
        let applied = GoutouMemoryApplier.apply(candidates, to: existing, personID: personID)
        guard applied.changed > 0 else {
            memoryNote = "这次没有新的可记内容"
            refreshPanel()
            return
        }
        GoutouMemoryStore.replaceAll(applied.items)
        memory = GoutouMemoryStore.load()
        memoryNote = "已从本次聊天更新 \(applied.changed) 条记忆"
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

        case .deleteMemory(let id):
            GoutouMemoryStore.remove(id: id)
            memory = GoutouMemoryStore.load()
            refreshPanel()

        case .clearMemory:
            memory = []
            memoryNote = nil
            GoutouMemoryStore.clear()
            refreshPanel()

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
}
