import Foundation

enum ChatRole: String, Codable {
    case me, other, system, unknown
}

struct ChatMessage: Codable, Equatable {
    let role: ChatRole
    let text: String
    let timestamp: Date?
}

struct ChatSnapshot: Codable, Equatable {
    let updatedAt: Date
    let messages: [ChatMessage]

    func isExpired(now: Date = Date(), maxAge: TimeInterval = 30) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return age < -5 || age > maxAge
    }
}
