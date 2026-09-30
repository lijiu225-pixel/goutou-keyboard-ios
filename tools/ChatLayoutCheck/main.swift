import CoreGraphics
import Foundation

// 剪贴板契约 + 版式解析 + 长图分片几何的冒烟测试。
// 纯 Foundation：CI 上直接 swiftc 编译运行，不需要模拟器，也不需要 Vision / UIKit。
//
//   swiftc -swift-version 5 Shared/GoutouChatClipboard.swift \
//     App/ChatLayoutParser.swift Shared/GoutouChatOCRGeometry.swift \
//     tools/ChatLayoutCheck/main.swift -o /tmp/chatlayoutcheck
//
// 覆盖不到的部分（这里跑不了，必须真机）：Vision 识别本身、PhotosPicker、SwiftUI 界面。

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func expectClipboardError(
    _ expected: GoutouChatClipboardError,
    _ label: String,
    _ body: () throws -> Void
) {
    do {
        try body()
        fatalError("\(label)：应该报错，但通过了")
    } catch let error as GoutouChatClipboardError {
        guard error == expected else {
            fatalError("\(label)：期望 \(expected)，实际 \(error)")
        }
    } catch {
        fatalError("\(label)：抛了别的错误 \(error)")
    }
}

func line(
    _ text: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double = 0.04,
    confidence: Float = 1
) -> ChatOCRLine {
    ChatOCRLine(
        text: text,
        box: ChatLayoutBox(x: x, y: y, width: width, height: height),
        confidence: confidence
    )
}

// MARK: - 1. 编解码

let sample = GoutouChatClipboardPayload(messages: [
    GoutouChatClipboardMessage(role: .other, text: "你好"),
    GoutouChatClipboardMessage(role: .me, text: "你好啊"),
])
let encoded = try GoutouChatClipboardCodec.encode(sample)

// 字段顺序由 sortedKeys 固定：format / messages / version，逐字比对能锁住契约。
expect(
    encoded == "{\"format\":\"goutou-chat\",\"messages\":[{\"role\":\"other\",\"text\":\"你好\"},{\"role\":\"me\",\"text\":\"你好啊\"}],\"version\":1}",
    "编码结果必须和约定的契约逐字一致，实际：\(encoded)"
)
let encodedAgain = try GoutouChatClipboardCodec.encode(sample)
expect(encodedAgain == encoded, "同一份内容两次编码必须完全一致（后面靠它判断重复导入）")

let decoded = try GoutouChatClipboardCodec.decode(encoded)
expect(decoded == sample, "自己编出来的必须自己能读回来")

let decodedPadded = try GoutouChatClipboardCodec.decode("\n  \(encoded)\n\n")
expect(decodedPadded == sample, "剪贴板常带首尾空白，必须容错")

// 中英混排 / 换行 / emoji / 引号都要原样往返
let mixed = GoutouChatClipboardPayload(messages: [
    GoutouChatClipboardMessage(role: .me, text: "Hello 你好 😂"),
    GoutouChatClipboardMessage(role: .other, text: "第一行\n第二行 \"引号\""),
])
let mixedText = try GoutouChatClipboardCodec.encode(mixed)
let mixedBack = try GoutouChatClipboardCodec.decode(mixedText)
expect(mixedBack == mixed, "中英混排与特殊字符必须往返不变")

// 顺序是语义的一部分，不能被编码顺手排掉
let reversed = GoutouChatClipboardPayload(messages: [
    GoutouChatClipboardMessage(role: .me, text: "你好啊"),
    GoutouChatClipboardMessage(role: .other, text: "你好"),
])
let reversedText = try GoutouChatClipboardCodec.encode(reversed)
expect(reversedText != encoded, "消息顺序不同，编码结果就必须不同")

// MARK: - 2. 电脑码拒绝各种脏输入

expectClipboardError(.notOurFormat, "空剪贴板") {
    _ = try GoutouChatClipboardCodec.decode("   \n ")
}
expectClipboardError(.notOurFormat, "随手复制的句子") {
    _ = try GoutouChatClipboardCodec.decode("你好，在吗")
}
expectClipboardError(.notOurFormat, "配置文本") {
    _ = try GoutouChatClipboardCodec.decode("GOUTOU-AI/1\nbase=https://a\nmodel=b\nkey=c")
}
expectClipboardError(.notOurFormat, "顶层是数组") {
    _ = try GoutouChatClipboardCodec.decode("[{\"role\":\"me\",\"text\":\"x\"}]")
}
expectClipboardError(.notOurFormat, "别家格式") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"other-app\",\"version\":1,\"messages\":[]}")
}
expectClipboardError(.invalidVersionType, "版本号是字符串") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":\"1\",\"messages\":[]}")
}
expectClipboardError(.unsupportedVersion(2), "未来版本") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":2,\"messages\":[]}")
}
expectClipboardError(.notOurFormat, "没有 version 字段") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"messages\":[]}")
}
expectClipboardError(.malformedJSON, "messages 不是数组") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":{}}")
}
expectClipboardError(.malformedJSON, "缺少 text") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[{\"role\":\"me\"}]}")
}
expectClipboardError(.malformedJSON, "缺少 role") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[{\"text\":\"x\"}]}")
}
expectClipboardError(.emptyMessages, "没有内容") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[]}")
}
expectClipboardError(.invalidRole(index: 1, value: "system"), "角色不认识") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[{\"role\":\"system\",\"text\":\"x\"}]}")
}
expectClipboardError(.invalidRole(index: 2, value: "unknown"), "未确定不许进剪贴板") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[{\"role\":\"me\",\"text\":\"x\"},{\"role\":\"unknown\",\"text\":\"y\"}]}")
}
expectClipboardError(.emptyMessage(index: 1), "空消息") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[{\"role\":\"me\",\"text\":\"   \"}]}")
}

let longText = String(repeating: "啊", count: GoutouChatClipboardCodec.maxMessageLength + 1)
expectClipboardError(.messageTooLong(index: 1, length: 2001, limit: 2000), "单条超长") {
    _ = try GoutouChatClipboardCodec.encode(GoutouChatClipboardPayload(messages: [
        GoutouChatClipboardMessage(role: .me, text: longText),
    ]))
}

let manyJSON = (0...(GoutouChatClipboardCodec.maxMessages)).map { _ in
    "{\"role\":\"other\",\"text\":\"x\"}"
}.joined(separator: ",")
expectClipboardError(.tooManyMessages(limit: 200), "条数超限") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[\(manyJSON)]}")
}
expect(
    !GoutouChatClipboardCodec.looksLikeOurFormat("你好，在吗"),
    "认格式必须对普通文本说不"
)
expect(GoutouChatClipboardCodec.looksLikeOurFormat(encoded), "认格式必须认得自己的输出")

// MARK: - 2b. version 必须是「数值类型的整数」

// 关键回归：`NSNumber.intValue` 会把 1.5 截成 1、把 true 当成 1，
// 于是坏数据被当成合法 v1 放进来。这些全都必须报「version 类型不对」。
func expectVersionRejected(_ json: String, _ label: String) {
    expectClipboardError(.invalidVersionType, label) {
        _ = try GoutouChatClipboardCodec.decode(json)
    }
}

/// 极端数值专用：Foundation 对超出表示范围的 JSON 数值有两条路 ——
/// 读成双精度（我们判 `.invalidVersionType`）或者干脆解析失败（`.malformedJSON`）。
/// 哪条都行，重要的是**绝不能**被当成合法 v1 放进来。这里只锁这个硬要求。
func expectVersionNotAccepted(_ json: String, _ label: String) {
    do {
        let payload = try GoutouChatClipboardCodec.decode(json)
        fatalError("\(label)：居然被接受了，解析出 \(payload.messages.count) 条")
    } catch let error as GoutouChatClipboardError {
        switch error {
        case .invalidVersionType, .malformedJSON:
            break
        default:
            fatalError("\(label)：期望「version 类型错」或「结构异常」，实际 \(error)")
        }
    } catch {
        fatalError("\(label)：抛了别的错误 \(error)")
    }
}

func versionJSON(_ rawVersionLiteral: String, messages: String = "[{\"role\":\"me\",\"text\":\"x\"}]") -> String {
    "{\"format\":\"goutou-chat\",\"version\":\(rawVersionLiteral),\"messages\":\(messages)}"
}

expectVersionRejected(versionJSON("1.5"), "version=1.5 不许截断成 1")
expectVersionRejected(versionJSON("0.9"), "version=0.9 不许截断成 0")
expectVersionRejected(versionJSON("-1.5"), "负数小数也不许截断")
expectVersionRejected(versionJSON("2.5"), "未来小数版本要按类型错处理")
expectVersionRejected(versionJSON("true"), "version=true 不许当成 1")
expectVersionRejected(versionJSON("false"), "version=false 不许当成 0")
expectVersionRejected(versionJSON("null"), "version=null")
expectVersionRejected(versionJSON("\"1\""), "字符串版本（引号形式）")
expectVersionRejected(versionJSON("\"1.0\""), "字符串版本 1.0")
expectVersionRejected(versionJSON("[]"), "数组当版本")
expectVersionRejected(versionJSON("{}"), "对象当版本")
// 超出表示范围的极端数值：不许崩，也不许环绕成一个小整数被放行。
expectVersionNotAccepted(versionJSON("99999999999999999999"), "超过 Int64 的整数")
expectVersionNotAccepted(versionJSON("1e400"), "会变成无穷大的数值")
expectVersionNotAccepted(versionJSON("-1e400"), "负方向的无穷大")
expectVersionNotAccepted(versionJSON("9.3e18"), "边界外的双精度整数")

// 带着自家 format 标记、但 JSON 本身坏掉：必须报「结构异常」，不能含糊成「不是我们的格式」。
expectClipboardError(.malformedJSON, "带自家标记但 JSON 截断了") {
    _ = try GoutouChatClipboardCodec.decode("{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[")
}

// 已知版本 1 必须照常接受；数值上等于 1 的浮点也按整数接受（口径写在实现里）。
let versionOne = try GoutouChatClipboardCodec.decode(versionJSON("1"))
expect(versionOne.messages.count == 1, "version=1 必须正常解析")
let versionOneFloat = try GoutouChatClipboardCodec.decode(versionJSON("1.0"))
expect(versionOneFloat.messages.count == 1, "version=1.0 数值上是整数，按整数接受")
// 未来整数版本：明确说「不支持版本」，而不是含糊的格式错。
expectClipboardError(.unsupportedVersion(3), "未来整数版本 3") {
    _ = try GoutouChatClipboardCodec.decode(versionJSON("3"))
}
expectClipboardError(.unsupportedVersion(0), "老版本 0") {
    _ = try GoutouChatClipboardCodec.decode(versionJSON("0"))
}

// MARK: - 2c. 体量上限：编码与解码同一套口径，且在解析前就拦住

expect(
    GoutouChatClipboardCodec.maxEncodedLength > GoutouChatClipboardCodec.maxMessages * GoutouChatClipboardCodec.maxMessageLength,
    "总长度上限必须装得下「满条数 × 满字数」的合法内容，否则会出现写得出来读不回去"
)

// 编码结果正好在上限内：可以往返。
let fullPayload = GoutouChatClipboardPayload(messages: (0..<GoutouChatClipboardCodec.maxMessages).map { index in
    GoutouChatClipboardMessage(
        role: index % 2 == 0 ? .me : .other,
        text: String(repeating: "啊", count: GoutouChatClipboardCodec.maxMessageLength)
    )
})
let fullEncoded = try GoutouChatClipboardCodec.encode(fullPayload)
expect(
    fullEncoded.count <= GoutouChatClipboardCodec.maxEncodedLength,
    "满条数 × 满字数的合法内容必须在上限之内，实际 \(fullEncoded.count)"
)
let fullBack = try GoutouChatClipboardCodec.decode(fullEncoded)
expect(fullBack == fullPayload, "满负荷内容也必须能往返（编码/解码上限口径一致）")

// 超过上限：在解析之前就报错，不要先去建对象树。
// 注意不能用「首尾加空白」来凑长度——`decode` 会先 trim，那是正常且必要的行为。
// 所以这里造一份**内容本身**就超标的合法格式 JSON。
func oversizedClipboardJSON(messageLength: Int) -> String {
    let text = String(repeating: "啊", count: messageLength)
    return "{\"format\":\"goutou-chat\",\"version\":1,\"messages\":[{\"role\":\"me\",\"text\":\"\(text)\"}]}"
}
let oversizedText = oversizedClipboardJSON(messageLength: GoutouChatClipboardCodec.maxEncodedLength)
expect(
    oversizedText.count > GoutouChatClipboardCodec.maxEncodedLength,
    "前提：这份下料确实超过总长度上限，实际 \(oversizedText.count)"
)
expectClipboardError(
    .inputTooLong(length: oversizedText.count, limit: GoutouChatClipboardCodec.maxEncodedLength),
    "超过总长度上限的剪贴板内容"
) {
    _ = try GoutouChatClipboardCodec.decode(oversizedText)
}
// 非 JSON 的巨型文本也是同一个错误（不是「不是我们的格式」），因为长度检查在最前面。
let giantNonJSONText = String(repeating: "a", count: GoutouChatClipboardCodec.maxEncodedLength + 1)
expectClipboardError(
    .inputTooLong(
        length: giantNonJSONText.count,
        limit: GoutouChatClipboardCodec.maxEncodedLength
    ),
    "巨量的非 JSON 文本"
) {
    _ = try GoutouChatClipboardCodec.decode(giantNonJSONText)
}

// MARK: - 3. 角色映射

expect(ChatLayoutRole.me.clipboardRole == .me, "我 → me")
expect(ChatLayoutRole.other.clipboardRole == .other, "对方 → other")
expect(
    ChatLayoutRole.unknown.clipboardRole == nil,
    "未确定不许写进剪贴板（复制前必须定下来）"
)

// MARK: - 4. 版式解析：左右分栏

let classic = ChatLayoutParser.parse(lines: [
    line("你好", x: 0.05, y: 0.10, width: 0.30),
    line("你好啊", x: 0.55, y: 0.20, width: 0.40),
])
expect(classic.count == 2, "两条消息必须分成两条，实际 \(classic.count)")
expect(classic.map { $0.role } == [.other, .me], "贴左是对方、贴右是我")
expect(classic.map { $0.text } == ["你好", "你好啊"], "文字要按顺序带上")

// 输入顺序被打乱也必须按阅读顺序输出
let shuffled = ChatLayoutParser.parse(lines: [
    line("你好啊", x: 0.55, y: 0.20, width: 0.40),
    line("你好", x: 0.05, y: 0.10, width: 0.30),
])
expect(shuffled.map { $0.text } == ["你好", "你好啊"], "阅读顺序必须按从上到下重新排")

// MARK: - 5. 多行气泡是一条消息

let wrapped = ChatLayoutParser.parse(lines: [
    line("周末有空吗", x: 0.05, y: 0.10, width: 0.30),
    line("一起吃饭", x: 0.05, y: 0.15, width: 0.30),
    line("好呀", x: 0.70, y: 0.25, width: 0.25),
])
expect(wrapped.count == 2, "多行气泡是一条，实际 \(wrapped.count)")
expect(wrapped[0].text == "周末有空吗\n一起吃饭", "气泡内多行用换行拼，实际 \(wrapped[0].text)")
expect(wrapped.map { $0.role } == [.other, .me], "多行气泡只判一次归属")

// MARK: - 6. 同一视觉行左右两侧不能并成一条

let sameRow = ChatLayoutParser.parse(lines: [
    line("在吗", x: 0.05, y: 0.10, width: 0.15),
    line("在", x: 0.80, y: 0.11, width: 0.15),
])
expect(sameRow.count == 2, "同高左右两条必须分开，实际 \(sameRow.count)")
expect(sameRow.map { $0.role } == [.other, .me], "同高左右按各自贴边判")

// MARK: - 7. 判不出来的一律「未确定」

let centered = ChatLayoutParser.parse(lines: [
    line("你好", x: 0.05, y: 0.10, width: 0.30),
    line("对方撤回了一条消息", x: 0.30, y: 0.30, width: 0.30),
    line("你好啊", x: 0.65, y: 0.50, width: 0.30),
])
expect(centered.count == 3, "三条要分开")
expect(centered[1].role == .unknown, "居中悬浮的通知类文字判不了，必须标未确定")
expect(centered[1].needsReview, "未确定要能被界面识别出来")

let oneFullWidth = ChatLayoutParser.parse(lines: [
    line("这是一整屏宽的一句话", x: 0.02, y: 0.10, width: 0.96),
])
expect(oneFullWidth.count == 1, "整屏宽的一句话就是一条，实际 \(oneFullWidth.count)")
expect(oneFullWidth[0].role == .unknown, "整屏宽的气泡左右都贴边，不能靠 midX 硬判")

// 截图里只有一侧的话：缺少另一侧参照，诚实标未确定，由「批量修正归属」一键定完
let onlyLeft = ChatLayoutParser.parse(lines: [
    line("你好", x: 0.05, y: 0.10, width: 0.30),
    line("在吗", x: 0.05, y: 0.20, width: 0.25),
])
expect(
    onlyLeft.allSatisfy { $0.role == .unknown },
    "只有一侧、没有对照参照时必须老实标未确定，不能猜"
)

// 内容区太窄（零散短文字）不做判断
let narrow = ChatLayoutParser.parse(lines: [
    line("好", x: 0.40, y: 0.10, width: 0.05),
    line("嗯", x: 0.40, y: 0.20, width: 0.05),
])
expect(narrow.allSatisfy { $0.role == .unknown }, "内容区宽度不够就别判角色")

// MARK: - 8. 边界与健壮性

expect(ChatLayoutParser.parse(lines: []).isEmpty, "没有行就没有消息")
expect(
    ChatLayoutParser.parse(lines: [line("   ", x: 0.05, y: 0.10, width: 0.30)]).isEmpty,
    "纯空白行必须丢掉"
)

// 置信度默认全留（宁可让用户自己删，也不静默吞内容）
let lowConfidenceLine = line("可能认错了", x: 0.05, y: 0.10, width: 0.30, confidence: 0.1)
expect(
    ChatLayoutParser.parse(lines: [lowConfidenceLine, line("你好啊", x: 0.55, y: 0.20, width: 0.40)]).count == 2,
    "默认不按置信度丢内容"
)
var strict = ChatLayoutThresholds.default
strict.minConfidence = 0.5
expect(
    ChatLayoutParser.parse(lines: [lowConfidenceLine, line("你好啊", x: 0.55, y: 0.20, width: 0.40)], thresholds: strict).count == 1,
    "调高阈值后该丢的才丢（阈值必须真的可配）"
)

// 长图：40 条左右轮流出现，不能被并成一坨
var longLines: [ChatOCRLine] = []
for index in 0..<20 {
    let offset = Double(index) * 0.05
    longLines.append(line("对方 \(index)", x: 0.05, y: 0.02 + offset, width: 0.30))
    longLines.append(line("我 \(index)", x: 0.65, y: 0.045 + offset, width: 0.30))
}
let longChat = ChatLayoutParser.parse(lines: longLines)
expect(longChat.count == 40, "长图 40 条要稳定分成 40 条，实际 \(longChat.count)")
expect(
    longChat.enumerated().allSatisfy { entry in
        entry.element.role == (entry.offset % 2 == 0 ? ChatLayoutRole.other : ChatLayoutRole.me)
    },
    "长图的归属不能串位"
)

// 置信度取组内最低值，界面据此提示「可能认错」
let mixedConfidence = ChatLayoutParser.parse(lines: [
    line("周末有空吗", x: 0.05, y: 0.10, width: 0.30, confidence: 0.9),
    line("一起吃饭", x: 0.05, y: 0.15, width: 0.30, confidence: 0.3),
    line("好呀", x: 0.70, y: 0.25, width: 0.25),
])
expect(mixedConfidence[0].confidence == 0.3, "一条消息的置信度取组内最低，实际 \(mixedConfidence[0].confidence)")

// MARK: - 9. 长截图分片：缩放口径

// 关键回归：1290×12000 的长截图如果按「最长边 2400」缩，宽度只剩 258 像素，文字直接不可读。
// 现在的口径：按最长边缩会让宽度掉到 480 以下，就改成按最小宽度定比例 ——
// 480 / 1290 = 0.372，宽度正好落在可读下限 480 上。
let longScreenshot = try ChatOCRTilingPlanner.plan(pixelWidth: 1290, pixelHeight: 12000)
expect(longScreenshot.strategy == .tiled, "长截图必须走分片路线")
expect(
    longScreenshot.workingWidth >= ChatOCRTilingConfig.default.minimumPixelDimension,
    "长截图的宽度必须保住可读下限，实际 \(longScreenshot.workingWidth)"
)
expect(
    longScreenshot.workingWidth > 1290 * (2400.0 / 12000.0),
    "宽度必须明显优于「最长边缩到 2400」的旧行为（旧行为只有 \(1290 * 2400 / 12000))，实际 \(longScreenshot.workingWidth)"
)
expect(
    abs(longScreenshot.scale - 480.0 / 1290.0) < 0.0001,
    "缩放比应该正好是「让宽度落在可读下限」的比例，实际 \(longScreenshot.scale)"
)
expect(longScreenshot.tiles.count > 1, "要切成多片，实际 \(longScreenshot.tiles.count)")
expect(
    longScreenshot.tiles.count <= ChatOCRTilingConfig.default.maxTileCount,
    "片数必须在上限内"
)

// 分片必须**无缝、无重叠**地铺满整张工作图（重叠靠识别内容的去重解决，切图本身不重叠）。
//
// 容差取 1 像素：工作图高度是 `pixelHeight × scale`，渲染出来会取整，
// 除不尽时各片高度也会差不到 1 像素。这点亚像素误差无关紧要，但断言不能假装它是 0。
//
// 这里同时锁死一个真实修过的 bug：曾经「从下往上倒推」的写法只在高度正好是片高整数倍时
// 成立，1290×12000 的实际计划（工作图 480×4465.116）会算出第 1 片 y=0 h=1400、
// 第 2 片 y=265.116 —— 两片叠在一起，中间一大段永远识别不到。
let tileSeamTolerance = 1.0
let tiles = longScreenshot.tiles
// 接缝断言失败时得能一次看全所有数字，所以先把计划整体打成一行日志。
print(
    "[诊断] 1290×12000 → strategy=\(longScreenshot.strategy) scale=\(longScreenshot.scale) "
        + "working=\(longScreenshot.workingWidth)×\(longScreenshot.workingHeight) "
        + "tiles=\(tiles.count) "
        + tiles.enumerated().map { "\($0.offset):[y=\($0.element.y) h=\($0.element.height) maxY=\($0.element.maxY)]" }
            .joined(separator: " ")
)
expect(tiles.first?.y == 0, "第一片必须从顶部开始，实际 \(String(describing: tiles.first?.y))")
expect(
    abs((tiles.last?.maxY ?? 0) - longScreenshot.workingHeight) < tileSeamTolerance,
    "最后一片必须正好贴住底边，实际 \(String(describing: tiles.last?.maxY)) vs \(longScreenshot.workingHeight)"
)
for index in 1..<tiles.count {
    expect(
        abs(tiles[index].y - tiles[index - 1].maxY) < tileSeamTolerance,
        "第 \(index + 1) 片必须紧接上一片，不能有缝也不能重叠（容差 \(tileSeamTolerance) 像素），"
            + "实际 \(tiles[index].y) vs \(tiles[index - 1].maxY)，"
            + "片高 \(tiles[index].height)，工作图高 \(longScreenshot.workingHeight)"
    )
    expect(
        tiles[index].width == longScreenshot.workingWidth,
        "每一片都要保留完整宽度（宽度就是文字清晰度的来源）"
    )
}
expect(
    tiles.allSatisfy { $0.height > 0 && $0.height <= ChatOCRTilingConfig.default.tileSpan + 0.001 },
    "每一片的高度必须落在 (0, 片高上限] 之间，不能出现零高或超高的片"
)
// 真正把整张工作图盖满：覆盖总长度必须等于工作图高度（不是「有几片」就算了）。
let covered = tiles.reduce(0.0) { $0 + $1.height }
expect(
    abs(covered - longScreenshot.workingHeight) < tileSeamTolerance,
    "所有片的高度加起来必须正好等于工作图高度，实际 \(covered) vs \(longScreenshot.workingHeight)"
)

// 除不尽的情形：2400 高的工作图切成 1400 的片 → 2 片各 1200，而不是「1400 + 1000」。
let unevenTiling = ChatOCRTilingPlanner.tileRects(workingWidth: 600, workingHeight: 2400, tileSpan: 1400)
expect(unevenTiling.count == 2, "2400 高切 1400 的片要两片，实际 \(unevenTiling.count)")
expect(
    unevenTiling.allSatisfy { abs($0.height - 1200) < 0.001 },
    "除不尽时把余数摊平，两片各 1200，实际 \(unevenTiling.map { $0.height })"
)
expect(unevenTiling[1].y == unevenTiling[0].maxY, "摊平之后两片依然严丝合缝")
expect(
    abs(unevenTiling[1].maxY - 2400) < 0.001,
    "最后一片依然贴底，实际 \(unevenTiling[1].maxY)"
)

// 普通竖屏截图：最长边超过 2400，缩到 2400 后正好单次识别完（不出多余的分片）。
let phoneScreenshot = try ChatOCRTilingPlanner.plan(pixelWidth: 1290, pixelHeight: 2796)
expect(
    phoneScreenshot.strategy == .singlePass,
    "缩到 2400 之后高度正好在单次范围内，不该白切片，实际 \(phoneScreenshot.strategy)"
)
expect(
    abs(phoneScreenshot.workingHeight - 2400) < 0.001,
    "普通竖屏截图应该缩到高度 2400，实际 \(phoneScreenshot.workingHeight)"
)

let smallScreenshot = try ChatOCRTilingPlanner.plan(pixelWidth: 1170, pixelHeight: 2000)
expect(smallScreenshot.strategy == .singlePass, "最长边不超过上限就单次识别")
expect(smallScreenshot.scale == 1, "能单次识别就不要降采样")
expect(
    abs(smallScreenshot.workingWidth - 1170) < 0.001 && abs(smallScreenshot.workingHeight - 2000) < 0.001,
    "单次识别不改尺寸"
)

// 刚越过单次上限：按最长边缩（宽度还够，不触发宽度保护），缩完工作图高度正好 2400，所以仍是单次。
// 这条专门锁住「没触发宽度保护」的那条路径。
let justOver = try ChatOCRTilingPlanner.plan(pixelWidth: 2000, pixelHeight: 2401)
expect(
    abs(justOver.scale - 2400.0 / 2401.0) < 0.0001,
    "刚刚越界时按最长边缩，实际 \(justOver.scale)"
)
expect(
    abs(justOver.workingHeight - 2400) < 0.001,
    "缩完高度正好压到 2400，实际 \(justOver.workingHeight)"
)
// 宽度保护只在「按最长边缩会把宽度压到不可读」时才生效。
// 1290×5000：按最长边缩（0.48）后宽度还有 619 像素，已经够读，就不该再套一次宽度保护
// —— 套了反而缩到 480，白白降质（这条曾经写错过）。
let widthAlreadyFine = try ChatOCRTilingPlanner.plan(pixelWidth: 1290, pixelHeight: 5000)
expect(
    abs(widthAlreadyFine.scale - 2400.0 / 5000.0) < 0.0001,
    "宽度本来就够读时不该额外缩放，实际 \(widthAlreadyFine.scale)"
)
expect(
    abs(widthAlreadyFine.workingWidth - 1290.0 * 2400 / 5000) < 0.001,
    "工作图宽度应该是 619.2，实际 \(widthAlreadyFine.workingWidth)"
)
expect(
    abs(widthAlreadyFine.workingHeight - 2400) < 0.001,
    "缩完高度正好 2400，实际 \(widthAlreadyFine.workingHeight)"
)
expect(
    widthAlreadyFine.strategy == .singlePass,
    "缩完高度没超上限就是单次识别，实际 \(widthAlreadyFine.strategy)"
)

// 真的进入宽度保护、并且长到需要分片：1290×7000 按最长边缩宽度只剩 442 像素（太窄），
// 改成按宽度定比例后工作图是 480×2604.7，出来 2 片。
let widthProtectedTiling = try ChatOCRTilingPlanner.plan(pixelWidth: 1290, pixelHeight: 7000)
expect(
    widthProtectedTiling.strategy == .tiled,
    "宽度保护下的 1290×7000 必须分片，实际 \(widthProtectedTiling.strategy)"
)
expect(
    abs(widthProtectedTiling.scale - 480.0 / 1290.0) < 0.0001,
    "缩放比应该正好是宽度比例，实际 \(widthProtectedTiling.scale)"
)
let expectedProtectedHeight = 7000 * 480.0 / 1290.0
expect(
    abs(widthProtectedTiling.workingHeight - expectedProtectedHeight) < 0.001,
    "工作图高度应该是 2604.65，实际 \(widthProtectedTiling.workingHeight)"
)
expect(
    widthProtectedTiling.tiles.count == 2,
    "2604.65 高的工作图切成 1400 的片是 2 片，实际 \(widthProtectedTiling.tiles.count)"
)

// MARK: - 10. 长截图分片：超出支持范围要明确报错，不能静默缩到不可用

func expectGeometryError(_ expected: ChatOCRGeometryError, _ label: String, _ body: () throws -> Void) {
    do {
        try body()
        fatalError("\(label)：应该报错，但通过了")
    } catch let error as ChatOCRGeometryError {
        guard error == expected else {
            fatalError("\(label)：期望 \(expected)，实际 \(error)")
        }
    } catch {
        fatalError("\(label)：抛了别的错误 \(error)")
    }
}

expectGeometryError(.emptyImage, "零尺寸图片") {
    _ = try ChatOCRTilingPlanner.plan(pixelWidth: 0, pixelHeight: 100)
}
expectGeometryError(.tooManyPixels(pixels: 100_000_000, limit: 64_000_000), "像素总数过大") {
    _ = try ChatOCRTilingPlanner.plan(pixelWidth: 10_000, pixelHeight: 10_000)
}
// 超高长图：片数超上限就要报错，报错信息里带实际片数。
// 像素总数先放开，好让这里测的是「片数超限」而不是「像素太多」。
var heightFocusedConfig = ChatOCRTilingConfig.default
heightFocusedConfig.maxPixelCount = 3_000_000_000
let extremeHeight = 1_000_000.0
// 这一段只是「预测会被判成几片」，好把期望值算出来；真正被断言的是下面那一次 plan。
// 不能直接调 plan：它会直接 throw，那就没法先断言前提了。
let extremeWorkingWidth = 1290 * (480.0 / 1290.0)
let extremeWorkingHeight = extremeHeight * (480.0 / 1290.0)
let extremeTiles = ChatOCRTilingPlanner.tileRects(
    workingWidth: extremeWorkingWidth,
    workingHeight: extremeWorkingHeight,
    tileSpan: heightFocusedConfig.tileSpan
).count
expect(extremeTiles > heightFocusedConfig.maxTileCount, "前提：这个高度确实超过片数上限，实际 \(extremeTiles)")
expectGeometryError(.tooTall(pixelHeight: extremeHeight, tileCount: extremeTiles), "超高长图") {
    _ = try ChatOCRTilingPlanner.plan(
        pixelWidth: 1290,
        pixelHeight: extremeHeight,
        config: heightFocusedConfig
    )
}
// 原图本来就窄（200 像素宽）：宽度保护只保证不放大，救不回来，所以直接明确报错，
// 而不是按 200 像素宽硬识（结果一定是错的，用户还得一条条删）。这条就是 widthTooSmall 的真实用途。
expectGeometryError(.widthTooSmall(pixelWidth: 200, minimum: 480), "原图本身太窄") {
    _ = try ChatOCRTilingPlanner.plan(pixelWidth: 200, pixelHeight: 9000)
}
// 宽度刚好挂在可读下限上就放行（1290×12000 正是这个位置）。
expect(
    abs(longScreenshot.workingWidth - ChatOCRTilingConfig.default.minimumPixelDimension) < 0.001,
    "宽度正好等于下限时要放行，实际 \(longScreenshot.workingWidth)"
)

// 每种支持范围问题的说明都必须能直接给用户看（非空、不含内部坐标）。
for error: ChatOCRGeometryError in [
    .emptyImage,
    .tooManyPixels(pixels: 100_000_000, limit: 64_000_000),
    .tooTall(pixelHeight: 200_000, tileCount: 143),
    .widthTooSmall(pixelWidth: 200, minimum: 480),
] {
    let text = error.localizedDescription
    expect(!text.isEmpty, "支持范围错误必须有给用户看的话：\(error)")
}

// MARK: - 11. 分片坐标换算回原图统一归一化

// 坐标换算用一份**合成**计划，数字好核对：1290×12000 原图，工作图 645×6000（缩放 0.5），
// 片高 1400 → 5 片，每片 1200 高，起点 0 / 1200 / 2400 / 3600 / 4800。
// （真实计划里 1290×12000 的缩放是 0.372，工作图 480×4465.116，除不尽、数字不好看，
//  所以这里用合成计划单独验换算，其余部分在上面用真实计划验。）
let syntheticPlan = ChatOCRTilingPlan(
    originalWidth: 1290,
    originalHeight: 12000,
    scale: 0.5,
    workingWidth: 645,
    workingHeight: 6000,
    strategy: .tiled,
    tiles: ChatOCRTilingPlanner.tileRects(workingWidth: 645, workingHeight: 6000, tileSpan: 1400)
)
expect(syntheticPlan.tiles.count == 5, "合成计划应该有 5 片，实际 \(syntheticPlan.tiles.count)")
let mapper = ChatOCRCoordinateMapper(plan: syntheticPlan)

// 第 2 片（工作图 y 从 1200 开始）里、贴着该片顶部的一行。
//
// 片内归一化 y=0…0.05 → 工作图像素 0…0.05×6000=0…300（**分母是整张工作图的 6000，不是片高**），
// 加片偏移 1200 → 工作图 1200…1500 → 除以缩放 0.5 回到原图 2400…3000 → 归一化 0.2…0.25。
// 这里同时锁住一个真修过的 bug：拿片高当分母会把 1200 高的片拉成整图高，行高和位置全错。
let secondTile = syntheticPlan.tiles[1]
expect(secondTile.y == 1200, "合成计划第 2 片起点应该是 1200，实际 \(secondTile.y)")
let mappedFromSecondTile = mapper.map(
    lines: [
        ChatOCRLine(
            text: "在吗",
            box: ChatLayoutBox(x: 0.1, y: 0, width: 0.5, height: 0.05),
            confidence: 0.9
        )
    ],
    tileOrigin: secondTile
)
let secondBox = mappedFromSecondTile[0].box
expect(
    abs(secondBox.minY - 2400.0 / 12000.0) < 0.0005,
    "第 2 片顶部的行必须换算到原图 y=0.2，实际 \(secondBox.minY)"
)
expect(
    abs(secondBox.maxY - 3000.0 / 12000.0) < 0.0005,
    "行高要按工作图尺寸换算回原图（0.25），实际 \(secondBox.maxY)"
)
// 横向：片内 x=0.1 → 工作图 0.1×645=64.5 → 原图 129 → 归一化 129/1290 = 0.1
expect(abs(secondBox.minX - 0.1) < 0.0005, "横向坐标换算，实际 \(secondBox.minX)")
expect(abs(secondBox.maxX - 0.6) < 0.0005, "横向右边界换算，实际 \(secondBox.maxX)")

// 同图不缩放时（scale=1）换算必须是恒等：这条能挡住「忘了除以原图边长」这类改动。
let identityMapper = ChatOCRCoordinateMapper(
    originalWidth: 645,
    originalHeight: 6000,
    workingWidth: 645,
    workingHeight: 6000,
    scale: 1
)
let identityBox = ChatLayoutBox(x: 0.2, y: 0.3, width: 0.1, height: 0.02)
expect(
    identityMapper.normalizedBox(fromWorkingNormalized: identityBox) == identityBox,
    "不缩放时坐标换算必须是恒等变换"
)

// 第一片和最后一片的边界也要落在原图范围内（0...1）。
// 注意这里用的是「片内占 20% 高」的框：整片高的框只有在片正好等于整张工作图时才合法，
// 拿它去断言是错的（那等于说「这一片就是整张图」）。
for (offset, tile) in syntheticPlan.tiles.enumerated() {
    let mapped = mapper.map(
        lines: [ChatOCRLine(text: "行 \(offset)", box: ChatLayoutBox(x: 0, y: 0, width: 1, height: 0.2), confidence: 1)],
        tileOrigin: tile
    )[0].box
    expect(
        mapped.minX >= -0.0001 && mapped.maxX <= 1.0001 && mapped.minY >= -0.0001 && mapped.maxY <= 1.0001,
        "第 \(offset + 1) 片的换算结果必须落在原图 0...1 内，实际 \(mapped)"
    )
    // 片内占 20% 高 → 工作图 0.2×6000=1200 像素 → 原图 2400 像素 → 归一化 0.2
    expect(
        abs((mapped.maxY - mapped.minY) - 0.2) < 0.0005,
        "第 \(offset + 1) 片的行高（原图归一化）应该是 0.2，实际 \(mapped.maxY - mapped.minY)"
    )
}
// 逐片检查：片内贴顶的一行换算到原图，必须正好落在这一片的实际起点上（不能整体偏上或偏下）。
for (offset, tile) in syntheticPlan.tiles.enumerated() {
    let mapped = mapper.map(
        lines: [ChatOCRLine(text: "贴 \(offset)", box: ChatLayoutBox(x: 0, y: 0, width: 0.2, height: 0.02), confidence: 1)],
        tileOrigin: tile
    )[0].box
    let expected = tile.y / syntheticPlan.scale / syntheticPlan.originalHeight
    expect(
        abs(mapped.minY - expected) < 0.0005,
        "第 \(offset + 1) 片贴顶的行应该落在原图 y=\(expected)，实际 \(mapped.minY)"
    )
}

// MARK: - 12. 分片重叠区的重复文字

func ocrLine(
    _ text: String,
    y: Double,
    x: Double = 0.1,
    width: Double = 0.35,
    height: Double = 0.02,
    confidence: Float = 0.9
) -> ChatOCRLine {
    ChatOCRLine(
        text: text,
        box: ChatLayoutBox(x: x, y: y, width: width, height: height),
        confidence: confidence
    )
}

// 同一行被两片各认了一次：只留一条。
let duplicated = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine("晚上一起吃饭吗", y: 0.500, confidence: 0.9),
    ocrLine("晚上一起吃饭吗", y: 0.498, confidence: 0.8),
])
expect(duplicated.count == 1, "重叠区的同一行文字必须只留一条，实际 \(duplicated.count)")
expect(duplicated[0].confidence == 0.9, "留下置信度更高的那条")
expect(duplicated[0].text == "晚上一起吃饭吗", "留下的是完整文字")

// 一片认全、一片只认到半句：留认全的那条（并且不改变顺序）。
let partialFirst = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine("吃饭吗", y: 0.5, width: 0.15),
    ocrLine("晚上一起吃饭吗", y: 0.5, width: 0.35, confidence: 0.95),
])
expect(partialFirst.count == 1, "半句和整句算同一条，实际 \(partialFirst.count)")
expect(partialFirst[0].text == "晚上一起吃饭吗", "留信息更全的那条，实际 \(partialFirst[0].text)")

// 顺序：重复被去掉之后，剩下的行仍按原顺序排（不能因为去重把后面的行提到前面）。
let orderPreserved = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine("第一句", y: 0.10),
    ocrLine("第二句", y: 0.50, confidence: 0.5),
    ocrLine("第二句 更全的版本", y: 0.50, confidence: 0.9),
    ocrLine("第三句", y: 0.90),
])
expect(
    orderPreserved.map { $0.text } == ["第一句", "第二句 更全的版本", "第三句"],
    "去重后的阅读顺序必须是「第一句 / 第二句 / 第三句」，实际 \(orderPreserved.map { $0.text })"
)

// 上下紧挨着的两条不同消息不能被误并（分片重叠区之外的高风险场景）。
let neighbouring = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine("在吗", y: 0.500, height: 0.02),
    ocrLine("在的", y: 0.525, height: 0.02),
])
expect(neighbouring.count == 2, "上下紧挨的两条不同消息必须都留着，实际 \(neighbouring.count)")

// 左右两侧同高不同文字（左右分栏）也不能被误并。
let leftAndRight = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine("在吗", y: 0.50, x: 0.05, width: 0.15),
    ocrLine("在", y: 0.50, x: 0.80, width: 0.15),
])
expect(leftAndRight.count == 2, "左右两条必须都留着，实际 \(leftAndRight.count)")

// 垂直几乎不重叠的同名文字（长图里重复出现的一句话）不能被当成重复。
let repeatedFarApart = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine("哈哈哈哈", y: 0.10),
    ocrLine("哈哈哈哈", y: 0.60),
])
expect(repeatedFarApart.count == 2, "长图里隔很远的两句同名话都要留着，实际 \(repeatedFarApart.count)")

// 空白差异不影响判断（分片边缘常带空格）。
let whitespaceVariant = ChatOCRLineDeduplicator.removingOverlapDuplicates([
    ocrLine(" 好的 ", y: 0.50),
    ocrLine("好的", y: 0.501, confidence: 0.7),
])
expect(whitespaceVariant.count == 1, "只差首尾空白的同一行算重复，实际 \(whitespaceVariant.count)")

// 分片重叠区最真实的样子：一片认全了，另一片只认到后半句，于是框更窄、中心点也偏了。
// 这种情况必须能认出「是同一行」（曾经用中心点距离判，直接判成了两行）。
expect(
    ChatOCRLineDeduplicator.isSameLine(
        ChatLayoutBox(x: 0.05, y: 0.40, width: 0.50, height: 0.03),
        ChatLayoutBox(x: 0.25, y: 0.402, width: 0.30, height: 0.03)
    ),
    "整句和后半句的框必须认成同一行（中心点差了 0.1，但横向重叠够）"
)
expect(
    !ChatOCRLineDeduplicator.isSameLine(
        ChatLayoutBox(x: 0.05, y: 0.40, width: 0.15, height: 0.03),
        ChatLayoutBox(x: 0.60, y: 0.40, width: 0.15, height: 0.03)
    ),
    "左右分栏的两条同高文字不能认成同一行（横向完全不重叠）"
)

// 纯逻辑函数本身也要经得起空输入。
expect(ChatOCRLineDeduplicator.removingOverlapDuplicates([]).isEmpty, "空输入返回空")
expect(
    ChatOCRLineDeduplicator.isSameText("abc", "abcd"),
    "互相包含算同一句话"
)
expect(
    !ChatOCRLineDeduplicator.isSameText("abc", "abd"),
    "只差一个字但不互相包含就不算同一句话（宁可让用户删）"
)
let substringDisabled = ChatOCRLineDeduplicator.removingOverlapDuplicates(
    [ocrLine("吃饭吗", y: 0.5, width: 0.15), ocrLine("晚上一起吃饭吗", y: 0.5, width: 0.35)],
    allowSubstring: false
)
expect(
    substringDisabled.count == 2,
    "关掉包含判定后这两条都要留着（阈值必须真的可配），实际 \(substringDisabled.count)"
)

print("ChatLayoutCheck passed")
