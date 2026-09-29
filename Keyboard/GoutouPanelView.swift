import UIKit

/// 军师面板的状态。控制器算，视图只负责画。
enum GoutouPanelState {
    /// 还没有结果；可选带一条顶部提示（读不到剪贴板 / 没开完全访问…）。
    case empty(banner: String?)
    /// 读不到剪贴板时的提示：额外给一个「复制开启完全访问的步骤」按钮。
    case needsFullAccess(String)
    case loading
    case failed(String)
    case ready(GoutouResult)
    case needsConfig
}

enum GoutouPanelAction {
    case back
    case importConfig
    case clearConfig
    case addSegment(GoutouSpeaker)
    case deleteSegment(Int)
    case importMemory
    case deleteMemory(Int)
    case clearMemory
    case selectProfile(String)
    case createProfile
    case deleteProfile(String)
    case renameActiveProfile
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
    /// 上下文段数不设上限；超过这个字数就在状态行提醒一下（请求会变慢，可能撞上 60 秒超时）。
    static let contextWarningLength = 4000

    private let topBarHeight: CGFloat = 30
    private let statusHeight: CGFloat = 26
    private let speakerHeight: CGFloat = 46
    private let spacing: CGFloat = 5
    private let padding: CGFloat = 6

    private let statusLabel = UILabel()
    private let bodyScroll = UIScrollView()
    private let bodyStack = UIStackView()
    private let settingsButton = NineKeyButton(type: .system)
    private let memoryButton = NineKeyButton(type: .system)
    private let profileButton = NineKeyButton(type: .system)

    private var state: GoutouPanelState = .empty(banner: nil)
    private var segments: [GoutouSegment] = []
    private var memory: [String] = []
    private var profiles: [GoutouPersonProfile] = []
    private var activeProfileID = ""
    private var configSummary = ""
    private enum Screen { case main, settings, memory, profiles }
    private var screen: Screen = .main

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
        // 顶栏中间改成「当前人物」——点它进档案列表
        profileButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        profileButton.applyStyle(background: GoutouTheme.function)
        profileButton.accessibilityLabel = "切换人物档案"
        profileButton.addTarget(self, action: #selector(didTapProfiles), for: .touchUpInside)
        settingsButton.setTitle("⚙ 设置", for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 13)
        settingsButton.applyStyle(background: GoutouTheme.function)
        settingsButton.addTarget(self, action: #selector(didTapSettings), for: .touchUpInside)

        for view in [back, profileButton, settingsButton] as [UIView] {
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

            profileButton.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 4),
            profileButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            profileButton.topAnchor.constraint(equalTo: container.topAnchor),
            profileButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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

        row.addArrangedSubview(makeClosureKey(title: GoutouSpeaker.opponent.buttonTitle, background: GoutouTheme.function, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .addSegment(.opponent))
        })
        row.addArrangedSubview(makeClosureKey(title: GoutouSpeaker.me.buttonTitle, background: GoutouTheme.function, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .addSegment(.me))
        })
        row.addArrangedSubview(makeClosureKey(title: GoutouSpeaker.background.buttonTitle, background: GoutouTheme.function, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .addSegment(.background))
        })
        memoryButton.setTitle(memoryButtonTitle, for: .normal)
        memoryButton.titleLabel?.font = .systemFont(ofSize: 13)
        memoryButton.applyStyle(background: GoutouTheme.function)
        memoryButton.accessibilityLabel = "长期档案（记忆）"
        memoryButton.addTarget(self, action: #selector(didTapMemory), for: .touchUpInside)
        row.addArrangedSubview(memoryButton)
        row.addArrangedSubview(makeClosureKey(title: "⟳分析", background: GoutouTheme.blue, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .analyze)
        })
        return row
    }

    private var memoryButtonTitle: String {
        memory.isEmpty ? "🧠 记忆" : "🧠 记忆\(memory.count)"
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

    func render(
        state: GoutouPanelState,
        segments: [GoutouSegment],
        memory: [String],
        profiles: [GoutouPersonProfile],
        activeProfileID: String,
        configSummary: String
    ) {
        self.state = state
        self.segments = segments
        self.memory = memory
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.configSummary = configSummary
        renderStatus()
        rebuildBody()
        updateTopTitles()
    }

    /// 面板顶部几个入口的标题：停在那一屏时显示「返回」。
    private func updateTopTitles() {
        settingsButton.setTitle(screen == .settings ? "⬅ 返回" : "⚙ 设置", for: .normal)
        memoryButton.setTitle(screen == .memory ? "⬅ 返回" : memoryButtonTitle, for: .normal)
        let name = profiles.first { $0.id == activeProfileID }?.name ?? "人物"
        profileButton.setTitle(screen == .profiles ? "⬅ 返回" : "👤 \(name)", for: .normal)
    }

    private func renderStatus() {
        if !segments.isEmpty {
            let listed = segments.enumerated()
                .map { "\($0.offset + 1).\($0.element.speaker.promptLabel)" }
                .joined(separator: " ")
            let total = segments.reduce(0) { $0 + $1.text.count }
            let tooLong = total > GoutouPanelView.contextWarningLength
            statusLabel.text = "上下文 \(segments.count) 段 · 约 \(total) 字\(tooLong ? "（偏长，可能要等更久）" : "") · \(listed)"
            statusLabel.textColor = tooLong ? GoutouTheme.warning : GoutouTheme.secondary
            return
        }
        switch state {
        case .empty(let banner):
            if let banner = banner, !banner.isEmpty {
                statusLabel.text = banner
                statusLabel.textColor = GoutouTheme.warning
                return
            }
        case .needsFullAccess(let banner):
            statusLabel.text = banner
            statusLabel.textColor = GoutouTheme.warning
            return
        default:
            break
        }
        statusLabel.text = "上下文 0 段 · 复制对方的话，点 👤对方 加进来"
        statusLabel.textColor = GoutouTheme.secondary
    }

    private func rebuildBody() {
        for subview in bodyStack.arrangedSubviews {
            bodyStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        if screen == .settings { buildSettingsBody(); return }
        if screen == .memory { buildMemoryBody(); return }
        if screen == .profiles { buildProfilesBody(); return }
        switch state {
        case .empty(let banner):
            if let banner = banner, !banner.isEmpty {
                bodyStack.addArrangedSubview(makeNoticeLabel(banner, color: GoutouTheme.warning))
            }
            appendSegmentList()
        case .needsFullAccess(let banner):
            bodyStack.addArrangedSubview(makeNoticeLabel(banner, color: GoutouTheme.warning))
            bodyStack.addArrangedSubview(makeActionButton(title: "复制开启完全访问的步骤", background: GoutouTheme.function, fontSize: 13) {
                self.delegate?.goutouPanel(self, didTrigger: .copyFullAccessSteps)
            })
            appendSegmentList()
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
                self.setScreen(.settings)
            })
        }
    }

    /// 上下文列表 + 清空按钮；没有上下文时给三步说明。
    private func appendSegmentList() {
        if segments.isEmpty {
            bodyStack.addArrangedSubview(makeNoticeLabel(
                "1. 长按对方的消息 → 复制\n2. 点上面 👤对方 / 🙋我 把内容加进来（段数不限，越多等得越久）\n3. 点 ⟳ 分析，选一条话术上屏",
                color: GoutouTheme.secondary
            ))
            return
        }
        for (index, segment) in segments.enumerated() {
            bodyStack.addArrangedSubview(makeSegmentRow(index: index, segment: segment))
        }
        bodyStack.addArrangedSubview(makeActionButton(title: "✕ 清空上下文", background: GoutouTheme.function, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .clearSegments)
        })
    }

    /// 一行上下文：左边是内容，右边一个 ✕ 单独删掉这一段。
    private func makeSegmentRow(index: Int, segment: GoutouSegment) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .fill

        let label = makeNoticeLabel(
            "\(index + 1). \(segment.speaker.promptLabel)：\(segment.text)",
            color: GoutouTheme.text
        )
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        let delete = NineKeyButton(type: .system)
        delete.setTitle("✕", for: .normal)
        delete.titleLabel?.font = .systemFont(ofSize: 14)
        delete.applyStyle(background: GoutouTheme.function)
        delete.accessibilityLabel = "删掉第 \(index + 1) 段"
        delete.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.goutouPanel(self, didTrigger: .deleteSegment(index))
        }, for: .touchUpInside)
        delete.widthAnchor.constraint(equalToConstant: 36).isActive = true
        row.addArrangedSubview(delete)
        return row
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

    /// 人物档案列表：一人一份上下文 / 记忆 / 总结，切谁用谁。
    private func buildProfilesBody() {
        bodyStack.addArrangedSubview(makeNoticeLabel(
            "每个档案的上下文、记忆、上次总结都是分开的；人格（分析风格）是共用的。",
            color: GoutouTheme.secondary
        ))
        for profile in profiles {
            bodyStack.addArrangedSubview(makeProfileRow(profile))
        }
        bodyStack.addArrangedSubview(makeActionButton(title: "➕ 新建人物档案", background: GoutouTheme.blue, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .createProfile)
        })
        bodyStack.addArrangedSubview(makeActionButton(title: "✏️ 用剪贴板第一行给当前人物改名", background: GoutouTheme.function, fontSize: 13) {
            self.delegate?.goutouPanel(self, didTrigger: .renameActiveProfile)
        })
    }

    private func makeProfileRow(_ profile: GoutouPersonProfile) -> UIView {
        let isActive = profile.id == activeProfileID
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .fill

        let title = NineKeyButton(type: .system)
        title.setTitle(
            "\(isActive ? "✅" : "👤") \(profile.name)　\(profile.segments.count) 段 · \(profile.memory.count) 条记忆",
            for: .normal
        )
        title.titleLabel?.font = .systemFont(ofSize: 13)
        title.titleLabel?.numberOfLines = 0
        title.titleLabel?.lineBreakMode = .byWordWrapping
        title.contentHorizontalAlignment = .left
        title.titleEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        title.applyStyle(background: isActive ? GoutouTheme.candidatePrimary : GoutouTheme.key)
        title.accessibilityLabel = "切到 \(profile.name)"
        title.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.goutouPanel(self, didTrigger: .selectProfile(profile.id))
        }, for: .touchUpInside)
        row.addArrangedSubview(title)

        if profiles.count > 1 {
            let delete = NineKeyButton(type: .system)
            delete.setTitle("✕", for: .normal)
            delete.titleLabel?.font = .systemFont(ofSize: 14)
            delete.applyStyle(background: GoutouTheme.function)
            delete.accessibilityLabel = "删掉 \(profile.name)"
            delete.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.delegate?.goutouPanel(self, didTrigger: .deleteProfile(profile.id))
            }, for: .touchUpInside)
            delete.widthAnchor.constraint(equalToConstant: 36).isActive = true
            row.addArrangedSubview(delete)
        }
        return row
    }

    /// 长期档案：每次分析都会带上，用来养这个军师。
    private func buildMemoryBody() {
        bodyStack.addArrangedSubview(makeNoticeLabel(
            memory.isEmpty
                ? "还没有长期档案。把「她生日 3 月 5 日」「我们认识三个月」这类事实复制过来，点下面导入。"
                : "长期档案 \(memory.count) 条（每次分析都会带上）：",
            color: memory.isEmpty ? GoutouTheme.secondary : GoutouTheme.text
        ))
        for (index, entry) in memory.enumerated() {
            bodyStack.addArrangedSubview(makeMemoryRow(index: index, text: entry))
        }
        bodyStack.addArrangedSubview(makeActionButton(title: "⬇️ 从剪贴板导入一条", background: GoutouTheme.blue, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .importMemory)
        })
        if !memory.isEmpty {
            bodyStack.addArrangedSubview(makeActionButton(title: "🗑 全部清空", background: GoutouTheme.function, fontSize: 13) {
                self.delegate?.goutouPanel(self, didTrigger: .clearMemory)
            })
        }
    }

    private func makeMemoryRow(index: Int, text: String) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .fill

        let label = makeNoticeLabel("- \(text)", color: GoutouTheme.text)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        let delete = NineKeyButton(type: .system)
        delete.setTitle("✕", for: .normal)
        delete.titleLabel?.font = .systemFont(ofSize: 14)
        delete.applyStyle(background: GoutouTheme.function)
        delete.accessibilityLabel = "删掉第 \(index + 1) 条记忆"
        delete.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.goutouPanel(self, didTrigger: .deleteMemory(index))
        }, for: .touchUpInside)
        delete.widthAnchor.constraint(equalToConstant: 36).isActive = true
        row.addArrangedSubview(delete)
        return row
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
        label.text = "分析中…（超时 \(Int(GoutouAIClient.timeout)) 秒）"
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
        setScreen(.settings)
    }

    @objc private func didTapMemory() {
        setScreen(.memory)
    }

    @objc private func didTapProfiles() {
        setScreen(.profiles)
    }

    @objc private func didTapCancel() {
        delegate?.goutouPanel(self, didTrigger: .cancel)
    }

    @objc private func didTapReply(_ sender: NineKeyButton) {
        guard let text = sender.payload else { return }
        delegate?.goutouPanel(self, didTrigger: .insertReply(text))
    }

    /// 切到某一屏；再点同一次标题就回到主屏。
    private func setScreen(_ target: Screen) {
        screen = (screen == target) ? .main : target
        updateTopTitles()
        rebuildBody()
    }

    /// 回到主屏（控制器在每次打开面板时调用）。
    func resetScreen() {
        screen = .main
        updateTopTitles()
        rebuildBody()
    }
}
