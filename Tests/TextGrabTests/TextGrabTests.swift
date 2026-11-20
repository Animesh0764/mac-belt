import AppKit
import CoreImage
import XCTest
@testable import BeltKit
@testable import TextGrabCore
@testable import TextGrabGadget

final class TextLayoutTests: XCTestCase {
    private func line(_ t: String, row: Int, x: Double = 0.05, h: Double = 0.05) -> RecognizedLine {
        RecognizedLine(t, x: x, y: 0.05 + Double(row) * 0.06, width: 0.3, height: h)
    }

    func testOrdersTopToBottomAndKeepsLineBreaks() {
        let lines = [line("second", row: 1), line("first", row: 0), line("third", row: 2)]
        XCTAssertEqual(TextLayout.text(from: lines, keepLineBreaks: true), "first\nsecond\nthird")
    }

    func testJoinsParagraphsAndHyphenatedWords() {
        let lines = [line("This is an exam-", row: 0), line("ple of a long", row: 1), line("sentence.", row: 2)]
        XCTAssertEqual(TextLayout.text(from: lines, keepLineBreaks: false), "This is an example of a long sentence.")
    }

    func testKeepsRealHyphens() {
        XCTAssertEqual(TextLayout.joinParagraph(["state-of-the-", "Art"]), "state-of-the- Art")
        XCTAssertEqual(TextLayout.joinParagraph(["x -", "y"]), "x - y")
    }

    func testGapStartsNewParagraph() {
        let lines = [line("Title", row: 0), line("Body one", row: 2), line("body two", row: 3)]
        XCTAssertEqual(TextLayout.text(from: lines, keepLineBreaks: false), "Title\n\nBody one body two")
        XCTAssertEqual(TextLayout.text(from: lines, keepLineBreaks: true), "Title\n\nBody one\nbody two")
    }

    func testSameRowPiecesJoinLeftToRight() {
        let lines = [line("Total", row: 0, x: 0.1), line("₹499", row: 0, x: 0.7), line("Tax", row: 1, x: 0.1)]
        XCTAssertEqual(TextLayout.text(from: lines, keepLineBreaks: true), "Total ₹499\nTax")
    }

    func testIgnoresBlankLines() {
        XCTAssertEqual(TextLayout.text(from: [line("  ", row: 0)], keepLineBreaks: true), "")
        XCTAssertEqual(TextLayout.text(from: [], keepLineBreaks: true), "")
    }

    func testSummaries() {
        XCTAssertEqual(TextLayout.summary(text: "", codes: []), "No text found")
        XCTAssertEqual(TextLayout.summary(text: "hello", codes: []), "Copied 1 word")
        XCTAssertEqual(TextLayout.summary(text: "hello there\nyou", codes: []), "Copied 3 words")
        XCTAssertEqual(TextLayout.summary(text: "", codes: ["https://example.com"]), "Copied link from QR code")
        XCTAssertEqual(TextLayout.summary(text: "", codes: ["WIFI:S:home;;"]), "Copied text from QR code")
        XCTAssertEqual(TextLayout.summary(text: "", codes: ["a", "b"]), "Copied 2 QR codes")
        XCTAssertEqual(TextLayout.summary(text: "scan me", codes: ["a"]), "Copied 2 words + QR code")
        XCTAssertEqual(TextLayout.clipboardText(text: "scan me", codes: ["a"]), "scan me\n\na")
        XCTAssertEqual(TextLayout.clipboardText(text: "", codes: ["a"]), "a")
    }

    func testPreview() {
        XCTAssertEqual(TextLayout.preview("ANNABELLE\nMYSTERY"), "ANNABELLE MYSTERY")
        let long = TextLayout.preview(String(repeating: "word ", count: 30))
        XCTAssertEqual(long.count, 48)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testSettingsDecodeOldFilesWithDefaults() throws {
        let s = try JSONDecoder().decode(TextGrabSettings.self, from: Data(#"{"keepLineBreaks":false}"#.utf8))
        XCTAssertFalse(s.keepLineBreaks)
        XCTAssertTrue(s.readCodes)
        XCTAssertEqual(s.hotkey, "ctrl+opt+t")
    }
}

/// Real Apple OCR on images drawn in memory. Never looks at your screen.
final class VisionRecognizerTests: XCTestCase {
    private func render(_ lines: [String], size: CGSize = CGSize(width: 900, height: 260)) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        for (i, l) in lines.enumerated() {
            (l as NSString).draw(at: NSPoint(x: 30, y: size.height - 80 - CGFloat(i) * 70), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    func testReadsRenderedText() async throws {
        let image = render(["Mac Belt grabs text", "straight off the screen"])
        let result = try await VisionRecognizer().recognize(image, readCodes: false)
        let text = TextLayout.text(from: result.lines, keepLineBreaks: true)
        XCTAssertEqual(text, "Mac Belt grabs text\nstraight off the screen")
    }

    func testReadsQRCode() async throws {
        let payload = "https://github.com/Animesh0764/mac-belt"
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        // Quiet zone so the detector is happy.
        let padded = qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -40, dy: -40)))
        let image = CIContext().createCGImage(padded, from: padded.extent)!
        let result = try await VisionRecognizer().recognize(image, readCodes: true)
        XCTAssertEqual(result.codes, [payload])
        let off = try await VisionRecognizer().recognize(image, readCodes: false)
        XCTAssertEqual(off.codes, [])
    }
}

// MARK: - Gadget

private struct FakeCapturer: RegionCapturer {
    var image: CGImage?
    var denied = false
    func capture() async throws -> CGImage? {
        if denied { throw CaptureError.notAllowed }
        return image
    }
}

private struct FakeRecognizer: TextRecognizer {
    var result: OCRResult
    func recognize(_ image: CGImage, readCodes: Bool) async throws -> OCRResult {
        readCodes ? result : OCRResult(lines: result.lines, codes: [])
    }
}

@MainActor
final class TextGrabGadgetTests: XCTestCase {
    private var dir: URL!
    private var hotkeys: HotkeyCenter!
    private var copied: [String] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-textgrab-\(UUID().uuidString)")
        hotkeys = HotkeyCenter()
        copied = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let blank: CGImage = {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    private func makeGadget(hotkey: String? = nil, image: CGImage? = blank,
                            result: OCRResult = OCRResult(lines: [], codes: [])) throws -> TextGrabGadget {
        var s = TextGrabSettings()
        if let hotkey { s.hotkey = hotkey } else { s.hotkeyEnabled = false }
        let store = SettingsStore(directory: dir)
        try store.save(s, key: "gadget.text-grab")
        let ui = BeltUI()
        ui.toastsEnabled = false
        let ctx = GadgetContext(id: "text-grab", store: store, hotkeys: hotkeys, permissions: PermissionBroker(),
                                events: EventBus(), ui: ui)
        let g = TextGrabGadget(context: ctx)
        g.capturer = FakeCapturer(image: image)
        g.recognizer = FakeRecognizer(result: result)
        g.hasPermission = { true }
        g.copy = { [weak self] in self?.copied.append($0) }
        return g
    }

    func testGrabCopiesText() async throws {
        let g = try makeGadget(result: OCRResult(lines: [RecognizedLine("Hello world", x: 0, y: 0)], codes: []))
        try g.start()
        await g.grabNow()
        XCTAssertEqual(copied, ["Hello world"])
        XCTAssertEqual(g.lastMessage, "Copied 2 words · press ⌘V to paste\n“Hello world”")
        g.stop()
    }

    func testEscCopiesNothingAndSaysNothing() async throws {
        let g = try makeGadget(image: nil)
        try g.start()
        await g.grabNow()
        XCTAssertEqual(copied, [])
        XCTAssertNil(g.lastMessage)
        g.stop()
    }

    func testNothingFoundLeavesClipboardAlone() async throws {
        let g = try makeGadget()
        try g.start()
        await g.grabNow()
        XCTAssertEqual(copied, [])
        XCTAssertEqual(g.lastMessage, "No text found")
        g.stop()
    }

    func testQRCodeCanBeSwitchedOff() async throws {
        let g = try makeGadget(result: OCRResult(lines: [], codes: ["https://example.com"]))
        try g.start()
        await g.grabNow()
        XCTAssertEqual(copied, ["https://example.com"])
        g.model.settings.readCodes = false
        await g.grabNow()
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(g.lastMessage, "No text found")
        g.stop()
    }

    func testWithoutPermissionItAsksInsteadOfGrabbing() async throws {
        let g = try makeGadget(result: OCRResult(lines: [RecognizedLine("secret", x: 0, y: 0)], codes: []))
        g.hasPermission = { false }
        // (grabNow() isn't called here: it would show the real system prompt.)
        try g.start()
        XCTAssertTrue(g.menuItems().first?.title.hasPrefix("Needs Screen Recording") ?? false)
        g.stop()
        XCTAssertEqual(copied, [])
    }

    func testDeniedCaptureAsksForPermission() async throws {
        let g = try makeGadget()
        g.capturer = FakeCapturer(image: nil, denied: true)
        var asked: [Bool] = []
        g.openPermission = { asked.append($0) }
        try g.start()
        await g.grabNow()
        XCTAssertEqual(asked, [true])
        XCTAssertEqual(g.lastMessage, "Allow Mac Belt under Screen Recording, then try again")
        await g.grabNow()
        XCTAssertEqual(asked, [true, false], "second time opens System Settings")
        XCTAssertTrue(g.lastMessage?.contains("Quit and reopen") ?? false)
        XCTAssertEqual(copied, [])
        g.stop()
    }

    func testOffMeansOff() async throws {
        let g = try makeGadget(result: OCRResult(lines: [RecognizedLine("x", x: 0, y: 0)], codes: []))
        try g.start()
        g.stop()
        await g.grabNow()
        XCTAssertEqual(copied, [], "a stopped gadget never grabs")
    }

    func testStartStopHundredTimesLeavesNothingBehind() throws {
        _ = try makeGadget(hotkey: "ctrl+opt+cmd+shift+f7")
        for _ in 0..<100 {
            let ui = BeltUI(); ui.toastsEnabled = false
            let ctx = GadgetContext(id: "text-grab", store: SettingsStore(directory: dir), hotkeys: hotkeys,
                                    permissions: PermissionBroker(), events: EventBus(), ui: ui)
            let g = TextGrabGadget(context: ctx)
            try g.start()
            XCTAssertEqual(hotkeys.registeredCount, 1)
            g.stop()
        }
        XCTAssertEqual(hotkeys.registeredCount, 0)
    }
}
