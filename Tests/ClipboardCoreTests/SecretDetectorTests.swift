import XCTest
@testable import ClipboardCore

/// Fake secrets are assembled at runtime from pieces so this file never contains a
/// key-shaped string (GitHub push protection would block the push otherwise).
enum Fake {
    static func chars(_ n: Int, from alphabet: String = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789") -> String {
        var rng = SystemRandomNumberGenerator()
        let a = Array(alphabet)
        return String((0..<n).map { _ in a[Int(rng.next() % UInt64(a.count))] })
    }
    static func hex(_ n: Int) -> String { chars(n, from: "0123456789abcdef") }
    static func upperDigits(_ n: Int) -> String { chars(n, from: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567") }
    static func join(_ parts: String...) -> String { parts.joined() }
}

final class SecretDetectorTests: XCTestCase {
    private func label(_ s: String) -> String? { SecretDetector.detect(s)?.label }

    // MARK: Known key formats

    func testKnownKeys() {
        let cases: [(String, String)] = [
            (Fake.join("sk", "-ant-", "api03-", Fake.chars(40)), "Anthropic API key"),
            (Fake.join("sk", "-proj-", Fake.chars(40)), "OpenAI API key"),
            (Fake.join("sk", "-", Fake.chars(48)), "OpenAI API key"),
            (Fake.join("sk", "_live_", Fake.chars(24)), "Stripe secret key"),
            (Fake.join("rk", "_test_", Fake.chars(24)), "Stripe secret key"),
            (Fake.join("wh", "sec_", Fake.chars(32)), "Webhook signing secret"),
            (Fake.join("gh", "p_", Fake.chars(36)), "GitHub token"),
            (Fake.join("git", "hub_pat_", Fake.chars(60)), "GitHub token"),
            (Fake.join("gl", "pat-", Fake.chars(20)), "GitLab token"),
            (Fake.join("AK", "IA", Fake.upperDigits(16)), "AWS access key"),
            (Fake.join("xo", "xb-", Fake.chars(12), "-", Fake.chars(24)), "Slack token"),
            (Fake.join("https://hooks.", "slack.com/services/T", Fake.upperDigits(8), "/B", Fake.upperDigits(8), "/", Fake.chars(24)), "Slack webhook"),
            (Fake.join("AI", "za", Fake.chars(35)), "Google API key"),
            (Fake.join("hf", "_", Fake.chars(34)), "Hugging Face token"),
            (Fake.join("np", "m_", Fake.chars(36)), "npm token"),
            (Fake.join("SG", ".", Fake.chars(22), ".", Fake.chars(43)), "SendGrid key"),
            (Fake.join("dop", "_v1_", Fake.hex(64)), "DigitalOcean token"),
            (Fake.join("rzp", "_live_", Fake.chars(14)), "Razorpay key"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(label(text), expected, text)
        }
    }

    func testKeyInsideLargerText() {
        let line = "export OPENAI_KEY=" + Fake.join("sk", "-proj-", Fake.chars(40))
        XCTAssertEqual(label(line), "OpenAI API key")
        let json = #"{"token": ""# + Fake.join("gh", "p_", Fake.chars(36)) + #""}"#
        XCTAssertEqual(label(json), "GitHub token")
    }

    func testPrivateKeyAndJWT() {
        let pem = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\n" + Fake.chars(64) + "\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(SecretDetector.detect(pem)?.kind, .privateKey)
        let jwt = Fake.join("eyJ", Fake.chars(20), ".eyJ", Fake.chars(40), ".", Fake.chars(43))
        XCTAssertEqual(SecretDetector.detect(jwt)?.kind, .jwt)
    }

    func testCredentialsInURL() {
        XCTAssertEqual(SecretDetector.detect("postgres://app:" + "s3cr3tPass" + "@db.example.com:5432/prod")?.kind, .credentialURL)
        XCTAssertNil(SecretDetector.detect("https://example.com/path?a=1"))
        XCTAssertNil(SecretDetector.detect("ssh git@github.com:user/repo.git"))
    }

    func testEnvLines() {
        XCTAssertEqual(SecretDetector.detect("DB_PASSWORD=" + "hunter2hunter2")?.kind, .envSecret)
        XCTAssertEqual(SecretDetector.detect("client_secret: \"" + Fake.chars(20) + "\"")?.kind, .envSecret)
        XCTAssertEqual(SecretDetector.detect("STRIPE_SECRET_KEY = " + Fake.chars(30))?.kind, .envSecret)
        // Mentions without a value aren't secrets.
        XCTAssertNil(SecretDetector.detect("Forgot your password? Reset it here."))
        XCTAssertNil(SecretDetector.detect("token: short"))
    }

    // MARK: One-time codes

    func testOneTimeCodes() {
        for s in ["482913", "48291375", "482 913", "482-913", "  482913\n",
                  "Your OTP is 4829. Do not share it.",
                  "482913 is your verification code for Example",
                  "Use code 73920 to sign in. Your code expires in 10 minutes",
                  "Your login code: 5521"] {
            XCTAssertEqual(SecretDetector.detect(s)?.kind, .oneTimeCode, s)
        }
    }

    func testNumbersThatAreNotCodes() {
        for s in ["2026", "1234", "12345", "₹4,999", "Order total 12999.00", "Call me at 9876543210",
                  "Meeting on 21/11/2026 at 1430", "Room 4021", "version 1.24.3"] {
            XCTAssertNil(SecretDetector.detect(s), s)
        }
    }

    // MARK: Generic tokens

    func testRandomTokenIsSecret() {
        XCTAssertEqual(SecretDetector.detect(Fake.chars(32))?.kind, .token)
        XCTAssertEqual(SecretDetector.detect(Fake.chars(40, from: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))?.kind, .token)
    }

    func testOrdinaryThingsAreNotSecrets() {
        let fine = [
            "Hello, see you at 5!",
            "https://github.com/Animesh0764/mac-belt/pull/12",
            "/Users/me/Documents/Projects/MacBelt/Sources/main.swift",
            "IMG_20261104_123456.jpg",
            "3f786850e387550fdab836ed7e6dc881de23001b",       // git SHA-1
            "123e4567-e89b-12d3-a456-426614174000",           // UUID
            "UIApplicationDidFinishLaunchingNotification",    // identifier, no digits
            "Fix-login-redirect-for-Safari-users-v2",         // branch-name slug
            "feature/ABC-1234-add-login",
            "someone@example.com",
            "func detect(_ raw: String) -> SecretMatch?",
            "",
            "   ",
        ]
        for s in fine { XCTAssertNil(SecretDetector.detect(s), s) }
    }

    func testMaskNeverRevealsMuch() {
        XCTAssertEqual(SecretDetector.mask("482913"), "48••••")
        let token = Fake.join("gh", "p_", Fake.chars(36))
        let masked = SecretDetector.mask(token)
        XCTAssertTrue(masked.hasPrefix("ghp"))
        XCTAssertEqual(masked.filter { $0 != "•" }.count, 3)
        XCTAssertLessThanOrEqual(masked.count, 9)
        XCTAssertEqual(SecretDetector.mask("ab"), "••••")
    }
}
