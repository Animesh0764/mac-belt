import Foundation

/// One line of text Vision found, with where it sits in the image.
/// Coordinates are normalised (0…1) with the origin at the **top-left**.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ text: String, x: Double, y: Double, width: Double = 0.5, height: Double = 0.05) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var midY: Double { y + height / 2 }
}

/// Turns recognised lines into the text you'd expect to paste.
public enum TextLayout {
    /// - keepLineBreaks: true keeps the lines as they appear on screen.
    ///   false joins each paragraph into one line (handy for text from PDFs and slides).
    ///   Either way, a clear vertical gap starts a new paragraph.
    public static func text(from lines: [RecognizedLine], keepLineBreaks: Bool) -> String {
        let rows = groupIntoRows(lines)
        guard !rows.isEmpty else { return "" }

        var paragraphs: [[String]] = [[rows[0].text]]
        for i in 1..<rows.count {
            let prev = rows[i - 1], cur = rows[i]
            let gap = cur.y - (prev.y + prev.height)
            let lineHeight = max(min(prev.height, cur.height), 0.0001)
            if gap > lineHeight * 0.9 {
                paragraphs.append([cur.text])
            } else {
                paragraphs[paragraphs.count - 1].append(cur.text)
            }
        }

        let joined = paragraphs.map { lines in
            keepLineBreaks ? lines.joined(separator: "\n") : joinParagraph(lines)
        }
        return joined.joined(separator: "\n\n")
    }

    /// Lines at the same height (e.g. table cells, two words Vision split) become one row,
    /// left to right, separated by a tab-like gap → a space.
    static func groupIntoRows(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let clean = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let sorted = clean.sorted { $0.midY < $1.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last?.first,
               abs(line.midY - last.midY) < min(line.height, last.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            let parts = row.sorted { $0.x < $1.x }
            let top = parts.map(\.y).min() ?? 0
            let bottom = parts.map { $0.y + $0.height }.max() ?? 0
            let left = parts.first?.x ?? 0
            let right = parts.map { $0.x + $0.width }.max() ?? 0
            return RecognizedLine(parts.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
                                  x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// "exam-" + "ple" → "example"; otherwise lines are joined with a space.
    static func joinParagraph(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            if out.isEmpty { out = line; continue }
            if out.hasSuffix("-"), let prev = out.dropLast().last, prev.isLetter,
               let next = line.first, next.isLowercase {
                out.removeLast()
                out += line
            } else {
                out += " " + line
            }
        }
        return out
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// What the toast says after a grab.
    public static func summary(text: String, codes: [String]) -> String {
        switch (text.isEmpty, codes.isEmpty) {
        case (true, true):
            return "No text found"
        case (true, false):
            let what = codes.count == 1 && isLink(codes[0]) ? "link" : "text"
            return codes.count == 1 ? "Copied \(what) from QR code" : "Copied \(codes.count) QR codes"
        default:
            let n = wordCount(text)
            let words = n == 1 ? "1 word" : "\(n) words"
            return codes.isEmpty ? "Copied \(words)" : "Copied \(words) + QR code"
        }
    }

    static func isLink(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    /// The final clipboard text: QR payloads first when that's all there is,
    /// otherwise the text with each QR payload on its own line after it.
    public static func clipboardText(text: String, codes: [String]) -> String {
        ([text] + codes).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
