import XCTest
import UIKit

final class PanelTests: XCTestCase {
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
}
