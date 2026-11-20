import Foundation

public enum SecretKind: String, Codable, Sendable {
    case oneTimeCode, apiKey, jwt, privateKey, credentialURL, envSecret, token
}

public struct SecretMatch: Equatable, Sendable {
    public let kind: SecretKind
    /// Human label: "One-time code", "GitHub token", "Private key"…
    public let label: String

    public init(_ kind: SecretKind, _ label: String) {
        self.kind = kind
        self.label = label
    }
}

/// Decides whether copied text is a secret that shouldn't be kept.
///
/// Tuned to avoid false alarms: a false positive means something useful vanishes from
/// history after 60 s, so ambiguous things (years, prices, git hashes, UUIDs, slugs)
/// are deliberately NOT treated as secrets.
public enum SecretDetector {
    public static func detect(_ raw: String) -> SecretMatch? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return nil }

        if text.contains("-----BEGIN"), text.range(of: "PRIVATE KEY-----") != nil {
            return SecretMatch(.privateKey, "Private key")
        }
        for (regex, label) in knownKeys where regex.firstMatch(in: text) {
            return SecretMatch(.apiKey, label)
        }
        if jwt.firstMatch(in: text) {
            return SecretMatch(.jwt, "Access token (JWT)")
        }
        if credentialURL.firstMatch(in: text) {
            return SecretMatch(.credentialURL, "Password in a URL")
        }
        if envSecret.firstMatch(in: text) {
            return SecretMatch(.envSecret, "Secret from a config file")
        }
        if isOneTimeCode(text) {
            return SecretMatch(.oneTimeCode, "One-time code")
        }
        if isHighEntropyToken(text) {
            return SecretMatch(.token, "Token")
        }
        return nil
    }

    /// "ghp_abc…" → "ghp••••••", "482913" → "48••••". Never reveals more than 3 characters.
    public static func mask(_ s: String) -> String {
        let visible = s.count >= 8 ? 3 : min(2, max(0, s.count - 2))
        return String(s.prefix(visible)) + String(repeating: "•", count: min(max(s.count - visible, 4), 6))
    }

    // MARK: - Rules

    static let knownKeys: [(Pattern, String)] = [
        (Pattern(#"sk-ant-[A-Za-z0-9_\-]{20,}"#), "Anthropic API key"),
        (Pattern(#"(?<![A-Za-z0-9])sk-(proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#), "OpenAI API key"),
        (Pattern(#"(?<![A-Za-z0-9])(sk|rk)_(live|test)_[A-Za-z0-9]{16,}"#), "Stripe secret key"),
        (Pattern(#"whsec_[A-Za-z0-9]{20,}"#), "Webhook signing secret"),
        (Pattern(#"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}"#), "GitHub token"),
        (Pattern(#"github_pat_[A-Za-z0-9_]{40,}"#), "GitHub token"),
        (Pattern(#"glpat-[A-Za-z0-9_\-]{20,}"#), "GitLab token"),
        (Pattern(#"(?<![A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])"#), "AWS access key"),
        (Pattern(#"xox[abposr]-[A-Za-z0-9\-]{10,}"#), "Slack token"),
        (Pattern(#"https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}"#), "Slack webhook"),
        (Pattern(#"AIza[0-9A-Za-z_\-]{35}"#), "Google API key"),
        (Pattern(#"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"#), "Hugging Face token"),
        (Pattern(#"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}"#), "npm token"),
        (Pattern(#"SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#), "SendGrid key"),
        (Pattern(#"dop_v1_[a-f0-9]{64}"#), "DigitalOcean token"),
        (Pattern(#"(?<![A-Za-z0-9])shp(at|ss|ca|pa)_[a-fA-F0-9]{32}"#), "Shopify token"),
        (Pattern(#"(?<![A-Za-z0-9])rzp_live_[A-Za-z0-9]{14,}"#), "Razorpay key"),
    ]

    static let jwt = Pattern(#"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#)

    /// postgres://user:pass@host, https://user:pass@host …
    static let credentialURL = Pattern(#"[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s:/@]+:[^\s@/]{3,}@[^\s]+"#)

    /// .env / config lines: API_KEY=…, client_secret: "…", DB_PASSWORD=…
    static let envSecret = Pattern(
        #"(?i)(?<![A-Za-z0-9])[A-Za-z0-9_]*(secret|token|password|passwd|api_?key|private_?key|access_?key)[A-Za-z0-9_]*["']?\s*[=:]\s*["']?[^\s"']{8,}"#)

    static let otpKeywords = Pattern(
        #"(?i)(otp|one[- ]time|verification code|security code|passcode|login code|sign[- ]in code|auth(entication)? code|2fa|code is|is your code|your code)"#)
    static let otpDigits = Pattern(#"(?<![\d.,₹$])\d{4,8}(?![\d,]|[.]\d)"#)
    static let bareCode = Pattern(#"^(\d{6,8}|\d{3}[ \-]\d{3})$"#)

    /// "482913", "482 913", or a short message with a code and a keyword
    /// ("Your OTP is 4829"). Plain 4-digit numbers alone (years, PINs on bills) are not codes.
    static func isOneTimeCode(_ text: String) -> Bool {
        if bareCode.firstMatch(in: text) { return true }
        return text.count <= 300 && otpKeywords.firstMatch(in: text) && otpDigits.firstMatch(in: text)
    }

    static let uuid = Pattern(#"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    /// A single random-looking token: 24–256 chars, mixed case and digits, high entropy.
    /// Excludes URLs, paths, file names, UUIDs, hex hashes, and word-slugs.
    static func isHighEntropyToken(_ text: String) -> Bool {
        guard (24...256).contains(text.count),
              !text.contains(where: { $0.isWhitespace }),
              !text.contains("."), !text.contains("/"), !text.contains("@"), !text.contains(":"),
              !uuid.firstMatch(in: text) else { return false }
        let hasUpper = text.contains(where: \.isUppercase)
        let hasLower = text.contains(where: \.isLowercase)
        let digits = text.filter(\.isNumber).count
        guard hasUpper, hasLower, digits >= 2 else { return false }
        // Slugs like "Fix-login-bug-for-Safari-v2": mostly real words.
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" })
        let wordy = parts.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) && $0.dropFirst().allSatisfy(\.isLowercase) }
        if parts.count >= 3 && wordy.count * 2 >= parts.count { return false }
        return shannonEntropy(text) >= 3.8
    }

    static func shannonEntropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }
}

/// Small NSRegularExpression wrapper (works on macOS 14 without the Swift Regex runtime quirks).
struct Pattern: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are constants; a typo should fail loudly in tests.
        re = try! NSRegularExpression(pattern: pattern)
    }

    func firstMatch(in s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
