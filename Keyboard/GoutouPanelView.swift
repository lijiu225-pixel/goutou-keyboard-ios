import UIKit

/// 军师面板的状态。控制器算，视图只负责画。
enum GoutouPanelState {
    /// 还没有结果；可选带一条顶部提示（读不到剪贴板 / 没开完全访问…）。
    case empty(banner: String?)
    case loading
    case failed(String)
    case ready(GoutouResult)
    case needsConfig
}

enum GoutouPanelAction {
    case back
    case toggleSettings
    case importConfig
    case clearConfig
    case addSegment(GoutouSpeaker)
    case analyze
    case cancel
    case clearSegments
    case copyFullAccessSteps
    case insertReply(String)
}

protocol GoutouPanelViewDelegate: AnyObject {
    func goutouPanel(_ panel: GoutouPanelView, didTrigger action: GoutouPanelAction)
}

/// 军师面板：点九键上的「军师」之后整屏换成它。
///
/// ```
/// 顶栏(30)   ⬅ 键盘 │ 狗头军师 │ ⚙ 设置
/// 状态行(26)  上下文 2 段 · 1.对方 2.我     / 或一条橙色提示
/// 归属行(46)  👤对方  🙋我  📝背景  ⟳分析
/// 结果区(余)  一行判断 + 最多 3 条话术（可滚）
/// ```
final class GoutouPanelView: UIView {

    weak var delegate: GoutouPanelViewDelegate?

    /// 没开「允许完全访问」时，一键复制这句给用户照着走。
    static let fullAccessSteps = "设置 → 通用 → 键盘 → 狗头军师 → 允许完全访问"

    private let topBarHeight: CGFloat = 30
    private let statusHeight: CGFloat = 26
    private let speakerHeight: CGFloat = 46
    private let spacing: CGFloat = 5
    private let padding: CGFloat = 6

    private let statusLabel = UILabel()
    private let bodyScroll = UIScrollView()
    private let bodyStack = UIStackView()
    private let settingsButton = NineKeyButton(type: .system)

    private var state: GoutouPanelState = .empty(banner: nil)
    private var segments: [GoutouSegment] = []
    private var configSummary = ""
    private var showingSettings = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 骨架

    private func setup() {
        backgroundColor = GoutouTheme.background

        let main = UIStackView(arrangedSubviews: [
            makeTopBar(),
            makeStatusRow(),
            makeSpeakerRow(),
            makeBodyArea(),
        ])
        main.axis = .vertical
        main.spacing = spacing
        main.translatesAutoresizingMaskIntoConstraints = false
        addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            main.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    private func makeTopBar() -> UIView {
        let container = UIView()
        container.heightAnchor.constraint(equalToConstant: topBarHeight).isActive = true

        let back = makeKey(title: "⬅ 键盘", background: GoutouTheme.function, fontSize: 13, action: #selector(didTapBack))
        let title = UILabel()
        title.text = "狗头军师"
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.textColor = GoutouTheme.text
        title.textAlignment = .center
        settingsButton.setTitle("⚙ 设置", for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 13)
        settingsButton.applyStyle(background: GoutouTheme.function)
        settingsButton.addTarget(self, action: #selector(didTapSettings), for: .touchUpInside)

        for view in [back, title, settingsButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            back.widthAnchor.constraint(equalToConstant: 76),
            back.topAnchor.constraint(equalTo: container.topAnchor),
            back.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 70),
            settingsButton.topAnchor.constraint(equalTo: container.topAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            title.leadingAnchor.constraint(equalTo: back.trailingAnchor),
            title.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeStatusRow() -> UIView {
        let container = UIView()
        container.heightAnchor.constraint(equalToConstant: statusHeight).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = GoutouTheme.secondary
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeSpeakerRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = spacing
        row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: speakerHeight).isActive = true

        row.addArrangedSubview(makeClosureKey(title: GoutouSpeaker.opponent.buttonTitle, background: GoutouTheme.function, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .addSegment(.opponent))
        })
        row.addArrangedSubview(makeClosureKey(title: GoutouSpeaker.me.buttonTitle, background: GoutouTheme.function, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .addSegment(.me))
        })
        row.addArrangedSubview(makeClosureKey(title: GoutouSpeaker.background.buttonTitle, background: GoutouTheme.function, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .addSegment(.background))
        })
        row.addArrangedSubview(makeClosureKey(title: "⟳ 分析", background: GoutouTheme.blue, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .analyze)
        })
        return row
    }

    private func makeBodyArea() -> UIView {
        let container = UIView()
        bodyScroll.showsVerticalScrollIndicator = true
        bodyScroll.alwaysBounceVertical = true
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false

        bodyStack.axis = .vertical
        bodyStack.spacing = 4
        bodyStack.alignment = .fill
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.addSubview(bodyStack)

        container.addSubview(bodyScroll)
        NSLayoutConstraint.activate([
            bodyScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: container.topAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            bodyStack.leadingAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.bottomAnchor),
            bodyStack.widthAnchor.constraint(equalTo: bodyScroll.frameLayoutGuide.widthAnchor),
        ])
        return container
    }

    // MARK: - 渲染

    func render(state: GoutouPanelState, segments: [GoutouSegment], configSummary: String) {
        self.state = state
        self.segments = segments
        self.configSummary = configSummary
        renderStatus()
        rebuildBody()
        settingsButton.setTitle(showingSettings ? "⬅ 返回" : "⚙ 设置", for: .normal)
    }

    private func renderStatus() {
        if !segments.isEmpty {
            let listed = segments.enumerated()
                .map { "\($0.offset + 1).\($0.element.speaker.promptLabel)" }
                .joined(separator: " ")
            statusLabel.text = "上下文 \(segments.count) 段 · \(listed)"
            statusLabel.textColor = GoutouTheme.secondary
            return
        }
        if case .empty(let banner) = state, let banner = banner, !banner.isEmpty {
            statusLabel.text = banner
            statusLabel.textColor = GoutouTheme.warning
            return
        }
        statusLabel.text = "上下文 0 段 · 复制对方的话，点 👤对方 加进来"
        statusLabel.textColor = GoutouTheme.secondary
    }

    private func rebuildBody() {
        for subview in bodyStack.arrangedSubviews {
            bodyStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        if showingSettings {
            buildSettingsBody()
            return
        }
        switch state {
        case .empty(let banner):
            if let banner = banner, !banner.isEmpty {
                bodyStack.addArrangedSubview(makeNoticeLabel(banner, color: GoutouTheme.warning))
                bodyStack.addArrangedSubview(makeActionButton(title: "复制开启完全访问的步骤", background: GoutouTheme.function, fontSize: 13) {
                    self.delegate?.goutouPanel(self, didTrigger: .copyFullAccessSteps)
                })
            }
            if segments.isEmpty {
                bodyStack.addArrangedSubview(makeNoticeLabel(
                    "1. 长按对方的消息 → 复制\n2. 点上面 👤对方 / 🙋我 把内容加进来（最多 3 段）\n3. 点 ⟳ 分析，选一条话术上屏",
                    color: GoutouTheme.secondary
                ))
            } else {
                for (index, segment) in segments.enumerated() {
                    bodyStack.addArrangedSubview(makeNoticeLabel(
                        "\(index + 1). \(segment.speaker.promptLabel)：\(segment.text)",
                        color: GoutouTheme.text
                    ))
                }
                bodyStack.addArrangedSubview(makeActionButton(title: "✕ 清空上下文", background: GoutouTheme.function, fontSize: 13) {
                    self.delegate?.goutouPanel(self, didTrigger: .clearSegments)
                })
            }
        case .loading:
            bodyStack.addArrangedSubview(makeLoadingRow())
        case .failed(let message):
            bodyStack.addArrangedSubview(makeNoticeLabel(message, color: GoutouTheme.warning))
            bodyStack.addArrangedSubview(makeActionButton(title: "重试", background: GoutouTheme.blue, fontSize: 14) {
                self.delegate?.goutouPanel(self, didTrigger: .analyze)
            })
        case .ready(let result):
            if !result.headline.isEmpty {
                bodyStack.addArrangedSubview(makeHeadlineLabel(result.headline))
            }
            for reply in result.replies {
                bodyStack.addArrangedSubview(makeReplyButton(reply))
            }
        case .needsConfig:
            bodyStack.addArrangedSubview(makeNoticeLabel("还没配置 AI 接口（Base URL / Model / Key）。", color: GoutouTheme.warning))
            bodyStack.addArrangedSubview(makeActionButton(title: "去配置", background: GoutouTheme.blue, fontSize: 14) {
                self.delegate?.goutouPanel(self, didTrigger: .toggleSettings)
            })
        }
    }

    private func buildSettingsBody() {
        bodyStack.addArrangedSubview(makeNoticeLabel(
            configSummary.isEmpty ? "当前配置：未导入" : "当前配置：\(configSummary)",
            color: GoutouTheme.text
        ))
        bodyStack.addArrangedSubview(makeActionButton(title: "⬇️ 从剪贴板导入配置", background: GoutouTheme.blue, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .importConfig)
        })
        bodyStack.addArrangedSubview(makeActionButton(title: "🗑 清空配置", background: GoutouTheme.function, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .clearConfig)
        })
        bodyStack.addArrangedSubview(makeNoticeLabel(
            "在「狗头军师」App 里填好 Base URL / Model / Key → 点「复制配置」→ 回这里导入。\nkey 只存在这台手机的键盘里，不进代码仓库。",
            color: GoutouTheme.secondary
        ))
    }

    private func makeLoadingRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = GoutouTheme.secondary
        spinner.startAnimating()
        row.addArrangedSubview(spinner)

        let label = UILabel()
        label.text = "分析中…（超时 15 秒）"
        label.font = .systemFont(ofSize: 13)
        label.textColor = GoutouTheme.secondary
        row.addArrangedSubview(label)

        let cancel = makeKey(title: "取消", background: GoutouTheme.function, fontSize: 13, action: #selector(didTapCancel))
        cancel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        cancel.heightAnchor.constraint(equalToConstant: 30).isActive = true
        row.addArrangedSubview(cancel)
        return row
    }

    private func makeHeadlineLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = GoutouTheme.text
        label.numberOfLines = 2
        return label
    }

    private func makeReplyButton(_ text: String) -> NineKeyButton {
        let button = NineKeyButton(type: .system)
        button.setTitle(text, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.contentHorizontalAlignment = .left
        button.titleEdgeInsets = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        button.applyStyle(background: GoutouTheme.key)
        button.accessibilityLabel = "话术：\(text)"
        button.addTarget(self, action: #selector(didTapReply(_:)), for: .touchUpInside)
        button.payload = text
        return button
    }

    private func makeNoticeLabel(_ text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func makeActionButton(title: String, background: UIColor, fontSize: CGFloat, action: @escaping () -> Void) -> NineKeyButton {
        let button = NineKeyButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.applyStyle(background: background)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func makeClosureKey(title: String, background: UIColor, fontSize: CGFloat, action: @escaping () -> Void) -> NineKeyButton {
        let button = NineKeyButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.applyStyle(background: background)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func makeKey(title: String, background: UIColor, fontSize: CGFloat, action: Selector) -> NineKeyButton {
        let button = NineKeyButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.applyStyle(background: background)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - 回调

    @objc private func didTapBack() {
        delegate?.goutouPanel(self, didTrigger: .back)
    }

    @objc private func didTapSettings() {
        delegate?.goutouPanel(self, didTrigger: .toggleSettings)
    }

    @objc private func didTapCancel() {
        delegate?.goutouPanel(self, didTrigger: .cancel)
    }

    @objc private func didTapReply(_ sender: NineKeyButton) {
        guard let text = sender.payload else { return }
        delegate?.goutouPanel(self, didTrigger: .insertReply(text))
    }

    func setShowingSettings(_ showing: Bool) {
        showingSettings = showing
        settingsButton.setTitle(showing ? "⬅ 返回" : "⚙ 设置", for: .normal)
        rebuildBody()
    }

    var isShowingSettings: Bool { showingSettings }
}
