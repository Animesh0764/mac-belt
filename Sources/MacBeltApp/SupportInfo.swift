import Foundation

/// Where "☕ Support Mac Belt" points. Mac Belt is free; this is the only "ask", and it never nags.
/// Forks: change these to your own links (or set them to nil to hide them).
enum SupportInfo {
    /// GitHub Sponsors page. Works only after Sponsors is set up for this account.
    static let githubSponsors = URL(string: "https://github.com/sponsors/Animesh0764")

    /// UPI ID for supporters in India, e.g. "name@okbank". nil hides the QR code.
    /// Use an ID made for this: anyone who scans the QR sees the account holder's name.
    static let upiID: String? = "singh.animesh.1@superyes"

    /// Name shown in the UPI app when someone scans the QR.
    static let upiPayeeName = "Mac Belt"

    static let repository = URL(string: "https://github.com/Animesh0764/mac-belt")!
    static let issues = URL(string: "https://github.com/Animesh0764/mac-belt/issues")!

    /// `upi://pay?...` link that any UPI app understands; encoded into the QR code.
    static var upiPayURL: String? {
        guard let id = upiID, !id.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "upi"
        c.host = "pay"
        c.queryItems = [
            URLQueryItem(name: "pa", value: id),
            URLQueryItem(name: "pn", value: upiPayeeName),
            URLQueryItem(name: "cu", value: "INR"),
            URLQueryItem(name: "tn", value: "Thanks for Mac Belt"),
        ]
        return c.string
    }
}
