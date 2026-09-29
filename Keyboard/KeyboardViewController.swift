import UIKit

/// 第一阶段的最小键盘：纯系统控件 + Auto Layout，不联网、不读剪贴板、不做中文。
/// 唯一目标是把「装得上 → 能添加 → 能显示 → 点字母能输入」这条链路跑通。
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

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        buildLayout()
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
}
