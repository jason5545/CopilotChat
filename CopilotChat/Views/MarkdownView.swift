import SwiftUI

struct MarkdownView: View {
    let text: String

    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .heading(let level, let text):
            inlineMarkdown(text)
                .font(headingFont(level: level))
                .fontWeight(.bold)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        inlineMarkdown(item)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.0).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        inlineMarkdown(item.1)
                    }
                }
            }

        case .blockquote(let text):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 3)
                inlineMarkdown(text)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            .padding(.vertical, 4)

        case .horizontalRule:
            Divider()
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
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
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
}
