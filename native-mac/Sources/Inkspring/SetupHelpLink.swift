import SwiftUI

struct SetupHelpLink: View {
    let title: String
    let topic: String
    let description: String

    init(_ title: String, topic: String, description: String? = nil) {
        self.title = title
        self.topic = topic
        self.description = description ?? title
    }

    var body: some View {
        Link(destination: URL(string: "https://inkspring.ai/help#" + topic)!) {
            StudioLinkOutLabel { Label(title, systemImage: "questionmark.circle") }
                .font(.callout)
        }
        .help(description + " (opens in your browser)")
        .accessibilityLabel(description)
    }
}
