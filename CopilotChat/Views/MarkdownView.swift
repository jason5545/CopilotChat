import SwiftUI

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block Types

    private enum Block {
        case paragraph(String)
        case codeBlock(language: String?, code: String)
        case heading(level: Int, text: String)
        case unorderedList([String])
        case orderedList([(Int, String)])
        case blockquote(String)
        case horizontalRule
        case empty
    }

    // MARK: - Parser

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code block
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Heading
            if let headingMatch = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                let level = headingMatch.1.count
                let text = String(headingMatch.2)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" })
                && line.trimmingCharacters(in: .whitespaces).count >= 3
                && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let chars = Set(line.trimmingCharacters(in: .whitespaces))
                if chars.count == 1 {
                    blocks.append(.horizontalRule)
                    i += 1
                    continue
                }
            }

            // Unordered list
            if line.firstMatch(of: /^[\s]*[-*+]\s+/) != nil {
                var items: [String] = []
                while i < lines.count, lines[i].firstMatch(of: /^[\s]*[-*+]\s+(.*)$/) != nil {
                    let content = lines[i].replacing(/^[\s]*[-*+]\s+/, with: "")
                    items.append(content)
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list
            if line.firstMatch(of: /^[\s]*\d+\.\s+/) != nil {
                var items: [(Int, String)] = []
                var num = 1
                while i < lines.count, lines[i].firstMatch(of: /^[\s]*(\d+)\.\s+(.*)$/) != nil {
                    let content = lines[i].replacing(/^[\s]*\d+\.\s+/, with: "")
                    items.append((num, content))
                    num += 1
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Blockquote
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix(">") {
                    let content = String(lines[i].dropFirst(1))
                        .trimmingCharacters(in: .init(charactersIn: " "))
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Empty line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph - collect consecutive non-empty lines
            var paraLines: [String] = []
            while i < lines.count
                    && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                    && !lines[i].hasPrefix("```")
                    && !lines[i].hasPrefix("#")
                    && !lines[i].hasPrefix(">")
                    && lines[i].firstMatch(of: /^[\s]*[-*+]\s+/) == nil
                    && lines[i].firstMatch(of: /^[\s]*\d+\.\s+/) == nil {
                paraLines.append(lines[i])
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            }
        }

        return blocks
    }

    // MARK: - Renderers

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
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

        case .empty:
            EmptyView()
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
