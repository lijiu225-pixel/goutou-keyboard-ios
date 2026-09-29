import Foundation
import UIKit

/// 狗头军师 iOS 键盘。纯系统控件 + Auto Layout，不联网、不读剪贴板。
///
/// 两种布局：
/// - 英文 26 键（原有实现，行为不变）
/// - 中文九键（对标 Android 稳定版布局；候选来自 GoutouPinyinTable，输入状态在 NineKeyInputEngine）
final class KeyboardViewController: UIInputViewController {

    // MARK: - 布局数据

    private let letterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    private let keyHeight: CGFloat = 46
    private let keySpacing: CGFloat = 6
    private let keyboardHeight: CGFloat = 258

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
    private var panelState: GoutouPanelState = .empty(banner: nil)
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
        segments = GoutouSegmentStore.load()
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
            view.backgroundColor = .secondarySystemBackground
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
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = keySpacing
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: keySpacing),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -keySpacing),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
        ])

        for row in letterRows {
            root.addArrangedSubview(makeLetterRow(row))
        }
        root.addArrangedSubview(makeBottomRow())

        // 键盘高度写死，横竖屏不做特殊处理（第一阶段不做额外功能）。
        let height = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    private func makeLetterRow(_ keys: [String]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = keySpacing
        row.distribution = .fillEqually
        row.alignment = .fill
        for key in keys {
            row.addArrangedSubview(makeKey(title: key, action: #selector(handleLetter(_:))))
        }
        return row
    }

    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = keySpacing
        row.distribution = .fill
        row.alignment = .fill

        var keys: [UIButton] = []

        if needsInputModeSwitchKey {
            let globe = makeKey(title: "🌐", action: #selector(handleNextKeyboard), fontSize: 20)
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            keys.append(globe)
        }

        let space = makeKey(title: "空格", action: #selector(handleSpace), fontSize: 15)
        keys.append(space)
        keys.append(makeKey(title: "⌫", action: #selector(handleDelete), fontSize: 20))
        keys.append(makeKey(title: "中", action: #selector(handleSwitchToChinese), fontSize: 18))
        keys.append(makeKey(title: "换行", action: #selector(handleReturn), fontSize: 15))

        for key in keys {
            row.addArrangedSubview(key)
        }

        // 空格键吃掉剩余宽度，其余按键给固定宽度。
        for key in keys where key !== space {
            key.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }
        return row
    }

    private func makeKey(title: String, action: Selector, fontSize: CGFloat = 22) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: fontSize, weight: .regular)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 7
        button.layer.masksToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: keyHeight).isActive = true
        return button
    }

    // MARK: - 按键动作

    @objc private func handleLetter(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(text)
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
        mentorPanel?.setShowingSettings(false)
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
        mentorPanel?.render(
            state: panelState,
            segments: segments,
            configSummary: config?.summary ?? ""
        )
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
            panelState = .failed("军师人格文件（GoutouSkill.md）没打进包，需要重新构建")
            refreshPanel()
            return
        }

        panelTask?.cancel()
        panelState = .loading
        refreshPanel()

        let systemPrompt = GoutouPrompt.systemPrompt(skill: skillText)
        let userMessage = GoutouPrompt.userMessage(segments: segments)
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
                    self.panelState = .ready(value)
                case .failure(let error):
                    self.panelState = .failed(error.message)
                }
                self.refreshPanel()
            }
        }
    }

    private func refreshNineKeyView() {
        nineKeyView?.render(
            digits: nineKeyEngine.digits,
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

        case .one:
            flushComposing()
            textDocumentProxy.insertText("，")

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

        case .toggleSettings:
            panel.setShowingSettings(!panel.isShowingSettings)

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
