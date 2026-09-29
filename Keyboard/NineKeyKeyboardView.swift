import UIKit

// MARK: - 主题（照搬 Android 稳定版的 Theme）

enum GoutouTheme {
    static let background = UIColor(goutouHex: 0x242424)
    static let key = UIColor(goutouHex: 0x3A3A3C)
    static let function = UIColor(goutouHex: 0x4A4A4C)
    static let blue = UIColor(goutouHex: 0x0A84FF)
    static let text = UIColor(goutouHex: 0xF5F5F7)
    static let secondary = UIColor(goutouHex: 0xA1A1A6)
    static let divider = UIColor(goutouHex: 0x505054)
    static let pressed = UIColor(goutouHex: 0x56565A)
    static let candidatePrimary = UIColor(goutouHex: 0x304E70)
    static let warning = UIColor(goutouHex: 0xFF9F0A)
}

private extension UIColor {
    convenience init(goutouHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 九键上的按键（带按下态）

final class NineKeyButton: UIButton {
    /// 数字键、符号键、候选词都用它携带要上屏的内容。
    var payload: String?
    var normalColor: UIColor = .clear
    var pressedColor: UIColor = GoutouTheme.pressed

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? pressedColor : normalColor
        }
    }

    func applyStyle(background: UIColor, cornerRadius: CGFloat = 8) {
        normalColor = background
        backgroundColor = background
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = GoutouTheme.divider.cgColor
        setTitleColor(GoutouTheme.text, for: .normal)
    }
}

// MARK: - 键盘 → 控制器的动作

enum NineKeyAction {
    /// 九键上 2…9：按数字序列查候选。
    case digit(Character)
    /// 数字 1：中文下直接上屏「，」（与 Android 一致）。
    case one
    /// 数字 0：有候选先上屏，没有就空格。
    case zero
    /// 标点列 / 数字页 / 符号页：直接上屏的文本。
    case literal(String)
    /// 候选词：清掉数字序列后直接上屏。
    case candidate(String)
    case delete
    case space
    case clear
    case showLetters
    case showNumbers
    case showSymbols
    /// 顶栏的「军师」：整屏切到军师面板。
    case openMentor
    case toggleMode
    case returnKey
    case nextKeyboard
}

/// 九键里的三个页面。
enum NineKeyPage {
    case nineKey
    case numbers
    case symbols
}

protocol NineKeyKeyboardViewDelegate: AnyObject {
    func nineKeyKeyboardView(_ view: NineKeyKeyboardView, didTrigger action: NineKeyAction)
}

// MARK: - 中文九键键盘

/// 中文九键界面。布局对标 Android 稳定版：候选条 +（标点列 | 1-9 宫格 | ⌫/重输/0 列）+ 底部动作行。
/// 这里只负责画和收按键；输入状态与 textDocumentProxy 都留在控制器里。
final class NineKeyKeyboardView: UIView {

    weak var delegate: NineKeyKeyboardViewDelegate?

    // 尺寸对标 Android 的 48/58/56dp，按 iPhone 的实际可用高度等比压缩。
    private let compositionHeight: CGFloat = 30
    private let candidateHeight: CGFloat = 42
    private let bottomHeight: CGFloat = 46
    private let keySpacing: CGFloat = 5
    private let outerPadding: CGFloat = 6
    private let punctuationWidth: CGFloat = 50
    private let functionColumnWidth: CGFloat = 62

    private let showsGlobeKey: Bool
    private let compositionLabel = UILabel()
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let keysContainer = UIStackView()

    private var page: NineKeyPage = .nineKey
    private var hasRenderedKeys = false
    private var renderedCandidateSignature = ""

    /// 数字页：完整 0-9，第 4 行挂回九键和删除。
    private let numberRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["ABC", "0", "⌫"],
    ]

    /// 符号页：标点 + 常用符号，第 4 行挂回九键和删除。
    private let symbolRows: [[String]] = [
        ["，", "。", "？", "！"],
        ["、", "；", "：", "…"],
        ["@", "#", "￥", "&"],
        ["ABC", "%", "*", "⌫"],
    ]

    private let punctuationKeys = ["，", "。", "？", "！"]

    init(showsGlobeKey: Bool) {
        self.showsGlobeKey = showsGlobeKey
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 骨架

    private func setup() {
        backgroundColor = GoutouTheme.background

        keysContainer.axis = .vertical
        keysContainer.spacing = keySpacing
        keysContainer.distribution = .fillEqually

        let main = UIStackView(arrangedSubviews: [
            makeCompositionStrip(),
            makeCandidateBar(),
            keysContainer,
            makeBottomRow(),
        ])
        main.axis = .vertical
        main.spacing = keySpacing
        main.translatesAutoresizingMaskIntoConstraints = false
        addSubview(main)

        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: outerPadding),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -outerPadding),
            main.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    private func makeCompositionStrip() -> UIView {
        let container = UIView()
        compositionLabel.font = .systemFont(ofSize: 15)
        compositionLabel.textColor = GoutouTheme.text
        compositionLabel.lineBreakMode = .byTruncatingTail
        compositionLabel.translatesAutoresizingMaskIntoConstraints = false

        let mentor = makeFunctionKey(title: "军师", fontSize: 13, action: #selector(didTapMentor))
        mentor.translatesAutoresizingMaskIntoConstraints = false
        mentor.accessibilityLabel = "打开狗头军师面板"

        container.addSubview(compositionLabel)
        container.addSubview(mentor)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: compositionHeight),
            compositionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            compositionLabel.trailingAnchor.constraint(lessThanOrEqualTo: mentor.leadingAnchor, constant: -8),
            compositionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            mentor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mentor.widthAnchor.constraint(equalToConstant: 64),
            mentor.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            mentor.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        return container
    }

    private func makeCandidateBar() -> UIView {
        let container = UIView()
        container.heightAnchor.constraint(equalToConstant: candidateHeight).isActive = true

        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.alwaysBounceHorizontal = true
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false

        candidateStack.axis = .horizontal
        candidateStack.spacing = 4
        candidateStack.alignment = .fill
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateStack)

        let clear = makeFunctionKey(title: "清空", action: #selector(didTapClear))
        clear.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(candidateScroll)
        container.addSubview(clear)

        NSLayoutConstraint.activate([
            candidateScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            candidateScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            candidateScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            candidateScroll.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -5),

            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor),

            clear.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            clear.widthAnchor.constraint(equalToConstant: 52),
            clear.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            clear.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        return container
    }

    private func makeBottomRow() -> UIView {
        let row = UIView()
        row.heightAnchor.constraint(equalToConstant: bottomHeight).isActive = true

        let symbolsKey = makeFunctionKey(title: "符", action: #selector(didTapShowSymbols))
        let numbersKey = makeFunctionKey(title: "123", action: #selector(didTapShowNumbers))
        let spaceKey = makeKey(title: "空格", background: GoutouTheme.key, fontSize: 15, action: #selector(didTapSpace))
        let languageKey = makeFunctionKey(title: "中英", action: #selector(didTapToggleMode))
        let returnKey = makeFunctionKey(title: "↵", fontSize: 19, action: #selector(didTapReturn))

        let leftPair = UIStackView(arrangedSubviews: [symbolsKey, numbersKey])
        leftPair.axis = .horizontal
        leftPair.spacing = keySpacing
        leftPair.distribution = .fillEqually

        let rightPair = UIStackView(arrangedSubviews: [languageKey, returnKey])
        rightPair.axis = .horizontal
        rightPair.spacing = keySpacing
        rightPair.distribution = .fillEqually

        let outer = UIStackView()
        outer.axis = .horizontal
        outer.spacing = keySpacing
        outer.distribution = .fill
        outer.translatesAutoresizingMaskIntoConstraints = false

        if showsGlobeKey {
            let globe = makeFunctionKey(title: "🌐", fontSize: 18, action: #selector(didTapNextKeyboard))
            globe.widthAnchor.constraint(equalToConstant: 48).isActive = true
            outer.addArrangedSubview(globe)
        }
        outer.addArrangedSubview(leftPair)
        outer.addArrangedSubview(spaceKey)
        outer.addArrangedSubview(rightPair)

        row.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            outer.topAnchor.constraint(equalTo: row.topAnchor),
            outer.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            // Android 底部行权重是 0.9 / 0.9 / 2.2 / 0.9 / 0.9，空格键单独放大
            leftPair.widthAnchor.constraint(equalTo: rightPair.widthAnchor),
            spaceKey.widthAnchor.constraint(equalTo: leftPair.widthAnchor, multiplier: 2.2 / 1.8),
        ])
        return row
    }

    // MARK: - 键盘区

    private func rebuildKeys() {
        for subview in keysContainer.arrangedSubviews {
            keysContainer.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        switch page {
        case .nineKey:
            keysContainer.addArrangedSubview(makeNineKeyArea())
        case .numbers:
            for row in numberRows {
                keysContainer.addArrangedSubview(makePageRow(row))
            }
        case .symbols:
            for row in symbolRows {
                keysContainer.addArrangedSubview(makePageRow(row))
            }
        }
    }

    private func makeNineKeyArea() -> UIView {
        let area = UIStackView()
        area.axis = .horizontal
        area.spacing = keySpacing
        area.distribution = .fill

        let punctuation = makePunctuationColumn()
        let grid = makeNumberGrid()
        let functions = makeFunctionColumn()

        area.addArrangedSubview(punctuation)
        area.addArrangedSubview(grid)
        area.addArrangedSubview(functions)

        punctuation.widthAnchor.constraint(equalToConstant: punctuationWidth).isActive = true
        functions.widthAnchor.constraint(equalToConstant: functionColumnWidth).isActive = true
        return area
    }

    private func makePunctuationColumn() -> UIView {
        let container = UIView()
        container.backgroundColor = GoutouTheme.function
        container.layer.cornerRadius = 8
        container.layer.masksToBounds = true
        container.layer.borderWidth = 1
        container.layer.borderColor = GoutouTheme.divider.cgColor

        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        for symbol in punctuationKeys {
            let button = NineKeyButton(type: .system)
            button.setTitle(symbol, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 19)
            button.applyStyle(background: .clear, cornerRadius: 0)
            button.layer.borderWidth = 0
            button.payload = symbol
            button.accessibilityLabel = "标点 \(symbol)"
            button.addTarget(self, action: #selector(didTapLiteral(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        return container
    }

    private func makeNumberGrid() -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = keySpacing
        grid.distribution = .fillEqually

        for keys in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]] {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = keySpacing
            row.distribution = .fillEqually
            for key in keys {
                row.addArrangedSubview(makeDigitKey(key))
            }
            grid.addArrangedSubview(row)
        }
        return grid
    }

    private func makeDigitKey(_ digit: String) -> NineKeyButton {
        let secondary = digit == "1" ? "分词" : NineKeyMapper.group(for: Character(digit)).uppercased()
        let button = makeKey(title: digit, background: GoutouTheme.key, fontSize: 21, action: #selector(didTapDigit(_:)))
        button.payload = digit
        button.accessibilityLabel = "按键 \(digit)，包含 \(secondary)"

        guard !secondary.isEmpty else { return button }

        let title = NSMutableAttributedString(
            string: digit,
            attributes: [
                .font: UIFont.systemFont(ofSize: 21),
                .foregroundColor: GoutouTheme.text,
            ]
        )
        title.append(NSAttributedString(
            string: "\n" + secondary,
            attributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: GoutouTheme.secondary,
            ]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))

        button.setAttributedTitle(title, for: .normal)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        return button
    }

    private func makeFunctionColumn() -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = keySpacing
        column.distribution = .fillEqually

        let delete = makeKey(title: "⌫", background: GoutouTheme.function, fontSize: 20, action: #selector(didTapDelete))
        delete.accessibilityLabel = "删除"
        let retype = makeFunctionKey(title: "重输", action: #selector(didTapClear))
        let zero = makeKey(title: "0", background: GoutouTheme.function, fontSize: 20, action: #selector(didTapZero))
        zero.accessibilityLabel = "数字 0"

        column.addArrangedSubview(delete)
        column.addArrangedSubview(retype)
        column.addArrangedSubview(zero)
        return column
    }

    private func makePageRow(_ keys: [String]) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = keySpacing
        row.distribution = .fillEqually

        for key in keys {
            let isDigit = key.count == 1 && key >= "0" && key <= "9"
            let background = isDigit ? GoutouTheme.key : GoutouTheme.function
            let button = makeKey(title: key, background: background, fontSize: 20, action: #selector(didTapPageKey(_:)))
            button.payload = key
            if key == "ABC" {
                button.accessibilityLabel = "回到九键字母"
            } else if key == "⌫" {
                button.accessibilityLabel = "删除"
            } else {
                button.accessibilityLabel = "按键 \(key)"
            }
            row.addArrangedSubview(button)
        }
        return row
    }

    // MARK: - 候选项

    private func rebuildCandidates(_ candidates: [String], digits: String) {
        for subview in candidateStack.arrangedSubviews {
            candidateStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        if candidates.isEmpty {
            let label = UILabel()
            label.text = digits.isEmpty ? "候选词" : "无候选"
            label.font = .systemFont(ofSize: 13)
            label.textColor = GoutouTheme.secondary
            label.textAlignment = .center
            candidateStack.addArrangedSubview(label)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        } else {
            for (index, word) in candidates.enumerated() {
                candidateStack.addArrangedSubview(makeCandidateKey(word: word, primary: index == 0))
            }
        }
        candidateScroll.setContentOffset(.zero, animated: false)
    }

    private func makeCandidateKey(word: String, primary: Bool) -> NineKeyButton {
        let button = NineKeyButton(type: .system)
        button.setTitle(word, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: primary ? 18 : 16)
        button.applyStyle(background: primary ? GoutouTheme.candidatePrimary : GoutouTheme.background)
        button.setTitleColor(primary ? GoutouTheme.text : GoutouTheme.secondary, for: .normal)
        button.payload = word
        button.accessibilityLabel = "候选词 \(word)"
        button.addTarget(self, action: #selector(didTapCandidate(_:)), for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: word.count > 2 ? 72 : 56).isActive = true
        return button
    }

    // MARK: - 对外渲染入口

    func render(digits: String, pinyinHint: String, candidates: [String], page: NineKeyPage) {
        compositionLabel.text = compositionText(digits: digits, pinyinHint: pinyinHint, page: page)

        let signature = candidates.joined(separator: "|") + "#" + digits
        if signature != renderedCandidateSignature {
            renderedCandidateSignature = signature
            rebuildCandidates(candidates, digits: digits)
        }

        if !hasRenderedKeys || page != self.page {
            self.page = page
            hasRenderedKeys = true
            rebuildKeys()
        }
    }

    /// 顶部一行显示"按了什么、可能是什么拼音"，空了就按页面显示提示。
    private func compositionText(digits: String, pinyinHint: String, page: NineKeyPage) -> String {
        if !digits.isEmpty {
            return pinyinHint.isEmpty ? digits : "\(digits) · \(pinyinHint)"
        }
        switch page {
        case .numbers: return "数字"
        case .symbols: return "符号"
        case .nineKey: return "中文九键 · 拼音"
        }
    }

    // MARK: - 造键

    private func makeKey(title: String, background: UIColor, fontSize: CGFloat, action: Selector) -> NineKeyButton {
        let button = NineKeyButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.applyStyle(background: background)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeFunctionKey(title: String, fontSize: CGFloat = 13, action: Selector) -> NineKeyButton {
        let button = makeKey(title: title, background: GoutouTheme.function, fontSize: fontSize, action: action)
        button.accessibilityLabel = title
        return button
    }

    // MARK: - 按键回调

    @objc private func didTapDigit(_ sender: NineKeyButton) {
        guard let payload = sender.payload, let key = payload.first else { return }
        delegate?.nineKeyKeyboardView(self, didTrigger: key == "1" ? .one : .digit(key))
    }

    @objc private func didTapZero() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .zero)
    }

    @objc private func didTapLiteral(_ sender: NineKeyButton) {
        guard let payload = sender.payload else { return }
        delegate?.nineKeyKeyboardView(self, didTrigger: .literal(payload))
    }

    @objc private func didTapCandidate(_ sender: NineKeyButton) {
        guard let payload = sender.payload else { return }
        delegate?.nineKeyKeyboardView(self, didTrigger: .candidate(payload))
    }

    @objc private func didTapPageKey(_ sender: NineKeyButton) {
        guard let payload = sender.payload else { return }
        switch payload {
        case "ABC":
            delegate?.nineKeyKeyboardView(self, didTrigger: .showLetters)
        case "⌫":
            delegate?.nineKeyKeyboardView(self, didTrigger: .delete)
        default:
            delegate?.nineKeyKeyboardView(self, didTrigger: .literal(payload))
        }
    }

    @objc private func didTapDelete() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .delete)
    }

    @objc private func didTapSpace() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .space)
    }

    @objc private func didTapClear() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .clear)
    }

    @objc private func didTapShowNumbers() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .showNumbers)
    }

    @objc private func didTapShowSymbols() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .showSymbols)
    }

    @objc private func didTapToggleMode() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .toggleMode)
    }

    @objc private func didTapReturn() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .returnKey)
    }

    @objc private func didTapNextKeyboard() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .nextKeyboard)
    }

    @objc private func didTapMentor() {
        delegate?.nineKeyKeyboardView(self, didTrigger: .openMentor)
    }
}
