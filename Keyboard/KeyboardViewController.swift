import UIKit

/// 狗头军师 iOS 键盘。纯系统控件 + Auto Layout，不联网、不读剪贴板。
///
/// 两种布局：
/// - 英文 26 键（原有实现，行为不变）
/// - 中文九键（对标 Android 稳定版布局，逻辑复用 NineKeyMapper / GoutouDictionary / NineKeyInputEngine）
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

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        let stored = UserDefaults.standard.string(forKey: KeyboardViewController.modeStorageKey)
        mode = Mode(rawValue: stored ?? "") ?? .chineseNineKey
        rebuildKeyboard()
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
        nineKeyEngine.clear()
        page = .nineKey

        switch mode {
        case .englishQWERTY:
            view.backgroundColor = .secondarySystemBackground
            buildLayout()
        case .chineseNineKey:
            view.backgroundColor = GoutouTheme.background
            buildNineKeyLayout()
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

        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let height = view.heightAnchor.constraint(equalToConstant: nineKeyHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        nineKeyView = keyboard
        refreshNineKeyView()
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
