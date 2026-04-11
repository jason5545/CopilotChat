import SwiftUI

/// Renders inline Markdown (bold, italic, code, links) using AttributedString.
/// Falls back to plain Text on parse failure.
struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}
