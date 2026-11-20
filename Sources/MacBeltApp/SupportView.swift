import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// "Buy me a coffee". Shown only when the user opens it from the menu. Never pops up by itself.
struct SupportView: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Text("☕").font(.system(size: 44))
            Text("Mac Belt is free, and always will be")
                .font(.title3.bold())
            Text("No paid tier, no tracking, no account. If it saved you from buying an app, you can buy me a coffee (or chai) instead. Totally optional.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = SupportInfo.githubSponsors {
                Link(destination: url) {
                    Label("Sponsor on GitHub", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let upi = SupportInfo.upiID, let payURL = SupportInfo.upiPayURL, let qr = QRCode.image(for: payURL) {
                VStack(spacing: 8) {
                    Text("In India? Scan with any UPI app").font(.headline)
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Text(upi).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(upi, forType: .string)
                            copied = true
                        }
                    }
                }
            }

            Divider()
            Text("Can't pay? Starring the repo, reporting a bug, or telling a friend helps just as much.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("Star Mac Belt on GitHub", destination: SupportInfo.repository).font(.footnote)
        }
        .padding(28)
        .frame(width: 440)
    }
}

enum QRCode {
    static func image(for text: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
