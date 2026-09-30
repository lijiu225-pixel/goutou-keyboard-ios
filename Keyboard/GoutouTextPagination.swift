import Foundation

/// Display-only paging. Joining all pages reproduces the original text verbatim.
/// Bound both characters and explicit newlines so newline-heavy text cannot create a giant UILabel.
enum GoutouTextPagination {
    static func pages(_ text: String, characters: Int = 600, lineBreaks: Int = 18) -> [String] {
        guard !text.isEmpty, characters > 0, lineBreaks > 0 else { return [] }
        var result: [String] = []
        var start = text.startIndex
        var count = 0
        var lines = 0
        for index in text.indices {
            count += 1
            let character = text[index]
            if character == "\n" || character == "\r" || character == "\r\n"
                || character == "\u{2028}" || character == "\u{2029}" { lines += 1 }
            let end = text.index(after: index)
            if count >= characters || lines >= lineBreaks {
                result.append(String(text[start..<end]))
                start = end
                count = 0
                lines = 0
            }
        }
        if start < text.endIndex { result.append(String(text[start...])) }
        return result
    }
}
