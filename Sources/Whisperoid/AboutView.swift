import AppKit
import SwiftUI

/// Deliberately holds no bindings and no mutable state. Everything shown here is
/// read once from the bundle, so there is nothing for SwiftUI to write back.
struct AboutView: View {

    var onShowAcknowledgements: (@MainActor () -> Void)?

    private static let author = "Michael Shvets"
    private static let email = "ms@solshark.me"

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
            }

            Text("Whisperoid")
                .font(.system(size: 20, weight: .semibold))

            Text("Local speech to text for macOS")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(Self.versionDescription)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            VStack(spacing: 4) {
                Text(Self.author)
                    .font(.callout)

                if let mailto = URL(string: "mailto:\(Self.email)") {
                    Link(Self.email, destination: mailto)
                        .font(.callout)
                } else {
                    Text(Self.email)
                        .font(.callout)
                }
            }

            if let onShowAcknowledgements {
                Button("Acknowledgements") { onShowAcknowledgements() }
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}
