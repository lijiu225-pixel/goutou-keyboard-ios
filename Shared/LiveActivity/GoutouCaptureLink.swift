import Foundation

/// Navigation only: the URL never carries a contact, message, or command to save/analyze.
enum GoutouCaptureLink {
    static let reviewURL = URL(string: "goutouinput://chat/review")!

    static func opensReview(_ url: URL) -> Bool {
        url.scheme?.lowercased() == reviewURL.scheme
            && url.host?.lowercased() == reviewURL.host
            && url.path == reviewURL.path
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
    }
}
