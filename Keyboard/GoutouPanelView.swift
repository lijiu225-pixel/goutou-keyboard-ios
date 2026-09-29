import UIKit

/// 军师面板的状态。控制器算，视图只负责画。
enum GoutouPanelState {
    /// 还没有结果；可选带一条顶部提示（读不到剪贴板 / 没开完全访问…）。
    case empty(banner: String?)
    /// 读不到剪贴板时的提示：额外给一个「复制开启完全访问的步骤」按钮。
    case needsFullAccess(String)
    case loading
    /// 失败：`summary` 给人看（「分析失败，返回格式异常」），`detail` 是技术原文（放「查看详情」里）
    case failed(summary: String, detail: String)
    case ready(GoutouResult)
    case needsConfig
}

/// 面板一次渲染需要的全部数据（控制器组装好丢进来）。
struct GoutouPanelSnapshot {
    var state: GoutouPanelState
    var segments: [GoutouSegment]
    var memory: [PersonMemory]
    var profiles: [GoutouPersonProfile]
    var activeProfileID: UUID
    /// 上一次成功的结果——失败时也保留，结果区高度不会忽上忽下
    var lastResult: GoutouResult?
    var configSummary: String
    /// 自动归纳完给一句提示（「已从本次聊天更新 X 条记忆」）
    var memoryNote: String?
}

enum GoutouPanelAction {
    case back
    case importConfig
    case clearConfig
    case addSegment(GoutouSpeaker)
    case deleteSegment(Int)
    case importMemory
    case deleteMemory(UUID)
    case clearMemory
    case selectProfile(UUID)
    case createProfile
    case deleteProfile(UUID)
    case renameProfile(UUID)
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

    private let bodyScroll = UIScrollView()
    private let bodyStack = UIStackView()
    private let settingsButton = NineKeyButton(type: .system)
    private let memoryButton = NineKeyButton(type: .system)
    private let profileButton = NineKeyButton(type: .system)
    private let analyzeButton = NineKeyButton(type: .system)
    private let analyzeSpinner = UIActivityIndicatorView(style: .medium)
    private let statusButton = NineKeyButton(type: .system)
    private var speakerButtons: [GoutouSpeaker: NineKeyButton] = [:]

    private var state: GoutouPanelState = .empty(banner: nil)
    private var segments: [GoutouSegment] = []
    private var memory: [PersonMemory] = []
    private var profiles: [GoutouPersonProfile] = []
    private var activeProfileID: UUID? = nil
    private var lastResult: GoutouResult?
    private var memoryNote: String?
    private var configSummary = ""
    /// 状态行点开＝看上下文明细；结果区默认只给结论 + 推荐回复，布局稳定
    private var showsContextDetail = false
    /// 失败时是否展开了技术详情
    private var showsFailureDetail = false
    /// 正在管理哪个人物（重命名 / 删除都放这儿，主界面不放）
    private var managingProfileID: String?
    /// 删除要二次确认
    private var confirmingDelete = false
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
        // 状态行只写「上下文 N 段 · M 字」；点一下才展开说话人明细（后者的旧写法太挤）
        statusButton.titleLabel?.font = .systemFont(ofSize: 12)
        statusButton.titleLabel?.lineBreakMode = .byTruncatingTail
        statusButton.contentHorizontalAlignment = .leading
        statusButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        statusButton.normalColor = .clear
        statusButton.pressedColor = GoutouTheme.pressed
        statusButton.layer.cornerRadius = 5
        statusButton.layer.masksToBounds = true
        statusButton.layer.borderWidth = 0
        statusButton.accessibilityLabel = "上下文明细"
        statusButton.addTarget(self, action: #selector(didTapStatus), for: .touchUpInside)
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusButton)
        NSLayoutConstraint.activate([
            statusButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusButton.topAnchor.constraint(equalTo: container.topAnchor),
            statusButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeSpeakerRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = spacing
        row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: speakerHeight).isActive = true

        for speaker in [GoutouSpeaker.opponent, .me, .background] {
            let button = makeClosureKey(title: speaker.buttonTitle, background: GoutouTheme.function, fontSize: 13) {
                self.delegate?.goutouPanel(self, didTrigger: .addSegment(speaker))
            }
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            speakerButtons[speaker] = button
            row.addArrangedSubview(button)
        }

        memoryButton.titleLabel?.font = .systemFont(ofSize: 13)
        memoryButton.titleLabel?.adjustsFontSizeToFitWidth = true
        memoryButton.titleLabel?.minimumScaleFactor = 0.75
        memoryButton.applyStyle(background: GoutouTheme.function)
        memoryButton.accessibilityLabel = "长期档案（记忆）"
        memoryButton.addTarget(self, action: #selector(didTapMemory), for: .touchUpInside)
        row.addArrangedSubview(memoryButton)

        analyzeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        analyzeButton.applyStyle(background: GoutouTheme.blue)
        analyzeButton.accessibilityLabel = "开始分析"
        analyzeButton.addTarget(self, action: #selector(didTapAnalyze), for: .touchUpInside)
        analyzeSpinner.color = .white
        analyzeSpinner.hidesWhenStopped = true
        analyzeSpinner.translatesAutoresizingMaskIntoConstraints = false
        analyzeButton.addSubview(analyzeSpinner)
        NSLayoutConstraint.activate([
            analyzeSpinner.centerXAnchor.constraint(equalTo: analyzeButton.centerXAnchor),
            analyzeSpinner.centerYAnchor.constraint(equalTo: analyzeButton.centerYAnchor),
        ])
        row.addArrangedSubview(analyzeButton)
        return row
    }

    private var memoryButtonTitle: String {
        memory.isEmpty ? "🧠 记忆" : "🧠 记忆（\(memory.count)）"
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

    func render(_ snapshot: GoutouPanelSnapshot) {
        self.state = snapshot.state
        self.segments = snapshot.segments
        self.memory = snapshot.memory
        self.profiles = snapshot.profiles
        self.activeProfileID = snapshot.activeProfileID
        self.lastResult = snapshot.lastResult
        self.memoryNote = snapshot.memoryNote
        self.configSummary = snapshot.configSummary
        renderStatus()
        rebuildBody()
        updateButtons()
    }

    /// 顶部入口 + 归属键的状态：停在那一屏显示「返回」、已有内容的键打勾、没内容的淡一点。
    private func updateButtons() {
        settingsButton.setTitle(screen == .settings ? "⬅ 返回" : "⚙ 设置", for: .normal)
        memoryButton.setTitle(screen == .memory ? "⬅ 返回" : memoryButtonTitle, for: .normal)
        let name = profiles.first { $0.id == activeProfileID }?.name ?? "当前人物"
        profileButton.setTitle(screen == .profiles ? "⬅ 返回" : "狗头军师 · \(name)", for: .normal)

        // 归属键：加了就打勾，没加就淡一点
        for (speaker, button) in speakerButtons {
            let filled = segments.contains { $0.speaker == speaker }
            button.setTitle("\(speaker.buttonTitle)\(filled ? " ✓" : "")", for: .normal)
            button.alpha = filled ? 1 : 0.6
        }
        memoryButton.alpha = memory.isEmpty ? 0.6 : 1

        // 分析键三态：分析 → 分析中…（转圈 + 禁用）→ 重新分析
        if case .loading = state {
            analyzeButton.setTitle("", for: .normal)
            analyzeButton.isEnabled = false
            analyzeButton.alpha = 1
            analyzeSpinner.startAnimating()
        } else {
            analyzeSpinner.stopAnimating()
            analyzeButton.isEnabled = true
            analyzeButton.setTitle(lastResult == nil ? "⟳分析" : "重新分析", for: .normal)
        }
    }

    private func renderStatus() {
        // 有需要提醒的事情（读不到剪贴板等）优先显示提示，否则只写「上下文 N 段 · M 字」
        var banner: String?
        switch state {
        case .empty(let text):
            if let text = text, !text.isEmpty { banner = text }
        case .needsFullAccess(let text):
            banner = text
        default:
            break
        }
        if let banner = banner {
            statusButton.setTitle(banner, for: .normal)
            statusButton.setTitleColor(GoutouTheme.warning, for: .normal)
            return
        }
        let total = segments.reduce(0) { $0 + $1.text.count }
        let tooLong = total > GoutouPanelView.contextWarningLength
        let suffix = showsContextDetail ? "（点一下收起明细）" : ""
        statusButton.setTitle("上下文 \(segments.count) 段 · \(total) 字\(tooLong ? "（偏长）" : "")\(suffix)", for: .normal)
        statusButton.setTitleColor(tooLong ? GoutouTheme.warning : GoutouTheme.secondary, for: .normal)
    }

    private func rebuildBody() {
        for subview in bodyStack.arrangedSubviews {
            bodyStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        if screen == .settings { buildSettingsBody(); return }
        if screen == .memory { buildMemoryBody(); return }
        if screen == .profiles { buildProfilesBody(); return }
        if showsContextDetail {
            buildContextDetailBody()
        } else {
            buildResultBody()
        }
    }

    /// 主屏：状态块（加载/失败/缺配置）+ 固定结构的「分析结论 / 推荐回复」。
    /// 结构固定是有意的——有没有结果都长一样，高度不会忽上忽下。
    private func buildResultBody() {
        switch state {
        case .loading:
            bodyStack.addArrangedSubview(makeLoadingRow())
        case .failed(let summary, let detail):
            bodyStack.addArrangedSubview(makeNoticeLabel(summary, color: GoutouTheme.warning))
            let actions = UIStackView()
            actions.axis = .horizontal
            actions.spacing = 6
            actions.distribution = .fillEqually
            actions.addArrangedSubview(makeActionButton(title: "重试", background: GoutouTheme.blue, fontSize: 14) {
                self.delegate?.goutouPanel(self, didTrigger: .analyze)
            })
            actions.addArrangedSubview(makeActionButton(
                title: showsFailureDetail ? "收起详情" : "查看详情",
                background: GoutouTheme.function,
                fontSize: 14
            ) {
                self.showsFailureDetail.toggle()
                self.rebuildBody()
            })
            bodyStack.addArrangedSubview(actions)
            if showsFailureDetail {
                bodyStack.addArrangedSubview(makeNoticeLabel(detail, color: GoutouTheme.secondary))
            }
        case .needsConfig:
            bodyStack.addArrangedSubview(makeNoticeLabel("还没配置 AI 接口（Base URL / Model / Key）。", color: GoutouTheme.warning))
            bodyStack.addArrangedSubview(makeActionButton(title: "去配置", background: GoutouTheme.blue, fontSize: 14) {
                self.setScreen(.settings)
            })
        case .needsFullAccess:
            bodyStack.addArrangedSubview(makeActionButton(title: "复制开启完全访问的步骤", background: GoutouTheme.function, fontSize: 13) {
                self.delegate?.goutouPanel(self, didTrigger: .copyFullAccessSteps)
            })
        case .empty(let banner):
            if let banner = banner, !banner.isEmpty {
                bodyStack.addArrangedSubview(makeNoticeLabel(banner, color: GoutouTheme.warning))
            }
        case .ready:
            break
        }

        bodyStack.addArrangedSubview(makeSectionHeader("分析结论"))
        if let note = memoryNote, !note.isEmpty {
            bodyStack.addArrangedSubview(makeNoticeLabel(note, color: GoutouTheme.secondary))
        }
        if let headline = lastResult?.headline, !headline.isEmpty {
            bodyStack.addArrangedSubview(makeHeadlineLabel(headline))
        } else {
            bodyStack.addArrangedSubview(makeNoticeLabel(
                "还没有结论。复制对方的对话 → 点 👤对方 → 点 ⟳分析。",
                color: GoutouTheme.secondary
            ))
        }

        bodyStack.addArrangedSubview(makeSectionHeader("推荐回复"))
        let replies = lastResult?.replies ?? []
        if replies.isEmpty {
            bodyStack.addArrangedSubview(makeNoticeLabel("还没有候选。", color: GoutouTheme.secondary))
        } else {
            for (index, reply) in replies.enumerated() {
                bodyStack.addArrangedSubview(makeReplyRow(index: index, text: reply))
            }
        }
    }

    private func makeSectionHeader(_ title: String) -> UILabel {
        let label = makeNoticeLabel(title, color: GoutouTheme.secondary)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    /// 一条推荐回复：文字（点一下也能插入）+ 右侧「插入」按钮。
    private func makeReplyRow(index: Int, text: String) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .fill

        let body = makeReplyButton("\(index + 1). \(text)")
        row.addArrangedSubview(body)

        let insert = NineKeyButton(type: .system)
        insert.setTitle("插入", for: .normal)
        insert.titleLabel?.font = .systemFont(ofSize: 13)
        insert.applyStyle(background: GoutouTheme.blue)
        insert.accessibilityLabel = "插入第 \(index + 1) 条"
        insert.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.goutouPanel(self, didTrigger: .insertReply(text))
        }, for: .touchUpInside)
        insert.widthAnchor.constraint(equalToConstant: 52).isActive = true
        row.addArrangedSubview(insert)
        return row
    }

    /// 点状态行展开的上下文明细：逐段列出 + 单段删除 + 清空。
    private func buildContextDetailBody() {
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
        if let managingID = managingProfileID, let profile = profiles.first(where: { $0.id == managingID }) {
            buildProfileManageBody(profile)
            return
        }
        bodyStack.addArrangedSubview(makeNoticeLabel(
            "每个档案的上下文、记忆、上次总结都是分开的；人格（分析风格）共用一份。点一下切换，长按进管理。",
            color: GoutouTheme.secondary
        ))
        for profile in profiles {
            bodyStack.addArrangedSubview(makeProfileRow(profile))
        }
        bodyStack.addArrangedSubview(makeActionButton(title: "➕ 新建人物", background: GoutouTheme.blue, fontSize: 14) {
            self.delegate?.goutouPanel(self, didTrigger: .createProfile)
        })
    }

    /// 长按人物进来的管理页：改名和删除都收在这儿，列表页不放 ✕。
    private func buildProfileManageBody(_ profile: GoutouPersonProfile) {
        bodyStack.addArrangedSubview(makeNoticeLabel("管理「\(profile.name)」", color: GoutouTheme.text))
        let detail = "\(profile.segments.count) 段上下文 · \(profile.memory.count) 条记忆"
            + (profile.summary == nil ? "" : " · 有上次总结")
        bodyStack.addArrangedSubview(makeNoticeLabel(detail, color: GoutouTheme.secondary))
        bodyStack.addArrangedSubview(makeActionButton(
            title: "✏️ 用剪贴板第一行改名",
            background: GoutouTheme.function,
            fontSize: 14
        ) {
            self.delegate?.goutouPanel(self, didTrigger: .renameProfile(profile.id))
        })
        bodyStack.addArrangedSubview(makeActionButton(
            title: confirmingDelete ? "⚠️ 再点一次确认删除" : "🗑 删除这个人",
            background: confirmingDelete ? GoutouTheme.warning : GoutouTheme.function,
            fontSize: 14
        ) {
            if self.confirmingDelete {
                self.confirmingDelete = false
                self.managingProfileID = nil
                self.delegate?.goutouPanel(self, didTrigger: .deleteProfile(profile.id))
            } else {
                self.confirmingDelete = true
                self.rebuildBody()
            }
        })
        bodyStack.addArrangedSubview(makeActionButton(title: "⬅ 返回人物列表", background: GoutouTheme.key, fontSize: 13) {
            self.managingProfileID = nil
            self.confirmingDelete = false
            self.rebuildBody()
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
        title.accessibilityIdentifier = profile.id.uuidString
        title.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.goutouPanel(self, didTrigger: .selectProfile(profile.id))
        }, for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didLongPressProfile(_:)))
        longPress.minimumPressDuration = 0.4
        title.addGestureRecognizer(longPress)
        row.addArrangedSubview(title)
        return row
    }

    @objc private func didLongPressProfile(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let id = gesture.view?.accessibilityIdentifier else { return }
        managingProfileID = id
        confirmingDelete = false
        rebuildBody()
    }

    /// 长期档案：每次分析都会带上，用来养这个军师。
    private func buildMemoryBody() {
        bodyStack.addArrangedSubview(makeNoticeLabel(
            memory.isEmpty
                ? "还没有长期档案。分析一次聊天会自动归纳；也可以把「她生日 3 月 5 日」这类事实复制过来手工导入。"
                : "长期档案 \(memory.count) 条（每次分析都会带上；自动归纳的会自己合并去重）：",
            color: memory.isEmpty ? GoutouTheme.secondary : GoutouTheme.text
        ))

        let stable = memory.filter { $0.category.isStable }
        let recent = memory.filter { !$0.category.isStable }
        if !stable.isEmpty {
            bodyStack.addArrangedSubview(makeSectionHeader("稳定事实 \(stable.count)"))
            for item in stable { bodyStack.addArrangedSubview(makeMemoryRow(item)) }
        }
        if !recent.isEmpty {
            bodyStack.addArrangedSubview(makeSectionHeader("近期状态 \(recent.count)"))
            for item in recent { bodyStack.addArrangedSubview(makeMemoryRow(item)) }
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

    private func makeMemoryRow(_ item: PersonMemory) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .fill

        let label = makeNoticeLabel("[\(item.category.label)] \(item.content)", color: GoutouTheme.text)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        let delete = NineKeyButton(type: .system)
        delete.setTitle("✕", for: .normal)
        delete.titleLabel?.font = .systemFont(ofSize: 14)
        delete.applyStyle(background: GoutouTheme.function)
        delete.accessibilityLabel = "删掉这条记忆"
        delete.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.goutouPanel(self, didTrigger: .deleteMemory(item.id))
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

    @objc private func didTapStatus() {
        showsContextDetail.toggle()
        renderStatus()
        rebuildBody()
    }

    @objc private func didTapAnalyze() {
        delegate?.goutouPanel(self, didTrigger: .analyze)
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
        managingProfileID = nil
        confirmingDelete = false
        updateButtons()
        rebuildBody()
    }

    /// 回到主屏（控制器在每次打开面板时调用）。
    func resetScreen() {
        screen = .main
        managingProfileID = nil
        confirmingDelete = false
        updateButtons()
        rebuildBody()
    }
}
