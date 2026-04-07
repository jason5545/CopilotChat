import SwiftUI

struct MarkdownView: View {
    let text: String

    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .onAppear { blocks = MarkdownParser.parse(text) }
        .onChange(of: text) { blocks = MarkdownParser.parse(text) }
    }

    // MARK: - Renderers

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.carbonSerif(.body))

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    HStack {
                        Text(language.uppercased())
                            .font(.carbonMono(.caption2, weight: .semibold))
                            .foregroundStyle(Color.carbonAccent.opacity(0.7))
                            .kerning(0.6)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.carbonMono(.callout))
                        .foregroundStyle(Color.carbonText.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.carbonCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Carbon.radiusSmall)
                    .stroke(Color.carbonBorder.opacity(0.3), lineWidth: 0.5)
            )

        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 4) {
                if level <= 2 {
                    inlineMarkdown(text)
                        .font(headingFont(level: level))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.carbonText)

                    if level == 1 {
                        Rectangle()
                            .fill(Color.carbonAccent.opacity(0.2))
                            .frame(height: 1)
                            .padding(.top, 2)
                    }
                } else {
                    inlineMarkdown(text)
                        .font(headingFont(level: level))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.carbonText)
                }
            }
            .padding(.top, level <= 2 ? 6 : 2)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Color.carbonAccent.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        inlineMarkdown(item)
                            .font(.carbonSerif(.body))
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(item.0).")
                            .font(.carbonMono(.callout, weight: .medium))
                            .foregroundStyle(Color.carbonAccent.opacity(0.6))
                            .monospacedDigit()
                            .frame(minWidth: 20, alignment: .trailing)
                        inlineMarkdown(item.1)
                            .font(.carbonSerif(.body))
                    }
                }
            }

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.carbonAccent.opacity(0.4))
                    .frame(width: 2.5)
                inlineMarkdown(text)
                    .font(.carbonSerif(.body))
                    .foregroundStyle(Color.carbonTextSecondary)
                    .italic()
                    .padding(.leading, 14)
            }
            .padding(.vertical, 4)

        case .horizontalRule:
            Rectangle()
                .fill(Color.carbonBorder.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .carbonSerif(.title2, weight: .bold)
        case 2: .carbonSerif(.title3, weight: .bold)
        case 3: .carbonSerif(.headline, weight: .semibold)
        default: .carbonSerif(.subheadline, weight: .semibold)
        }
    }
}

#Preview {
    ScrollView {
        MarkdownView(text: """
        # Hello World

        This is a **bold** and *italic* paragraph with `inline code`.

        ## Code Block

        ```swift
        func hello() {
            print("Hello, World!")
        }
        ```

        ### Lists

        - Item one
        - Item two
        - Item three

        1. First
        2. Second
        3. Third

        > This is a blockquote
        > spanning multiple lines

        ---

        [Link example](https://example.com)
        """)
        .padding()
    }
    .background(Color.carbonBlack)
    .preferredColorScheme(.dark)
}
