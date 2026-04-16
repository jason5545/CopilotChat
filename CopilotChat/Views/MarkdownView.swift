import SwiftUI

struct MarkdownView: View {
    let text: String

    @State private var blocks: [MarkdownBlock] = []
    @State private var parseTask: Task<Void, Never>?
    @State private var attributedCache: [String: AttributedString] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks, id: \.debugId) { block in
                renderBlock(block)
            }
        }
        .tint(Color.carbonAccent)
        .onAppear { scheduleParse(text, debounce: false) }
        .onChange(of: text) { _, newText in scheduleParse(newText, debounce: true) }
    }

    private func scheduleParse(_ input: String, debounce: Bool) {
        parseTask?.cancel()
        parseTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let parsed = await Task.detached { MarkdownParser.parse(input) }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
        }
    }

    private func cachedAttributedString(for text: String) -> AttributedString? {
        if let cached = attributedCache[text] { return cached }
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            if attributedCache.count > 100 { attributedCache.removeAll(keepingCapacity: true) }
            attributedCache[text] = attributed
            return attributed
        }
        return nil
    }

    // MARK: - Renderers

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.carbonSerif(.body))

        case .codeBlock(let language, let code):
            if let lang = language?.lowercased(), (lang == "diff" || lang == "patch"), DiffParser.isDiffContent(code) {
                let changes = DiffParser.parse(code)
                if !changes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(changes) { change in
                                DiffStatLabel(additions: change.additions, deletions: change.deletions)
                            }
                            DiffView(changes: changes)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.carbonCodeBg)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: Carbon.radiusSmall)
                            .stroke(Color.carbonBorder.opacity(0.3), lineWidth: 0.5)
                    )
                } else {
                    standardCodeBlock(language: language, code: code)
                }
            } else {
                standardCodeBlock(language: language, code: code)
            }

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

        case .taskList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
                            .font(.callout)
                            .foregroundStyle(item.isComplete ? Color.carbonAccent : Color.carbonTextTertiary)
                            .padding(.top, 1)
                        inlineMarkdown(item.text)
                            .font(.carbonSerif(.body))
                            .strikethrough(item.isComplete ? true : false)
                    }
                }
            }

        case .table(let headers, let alignments, let rows):
            tableBlock(headers: headers, alignments: alignments, rows: rows)
        }
    }

    // MARK: - Table

    @ViewBuilder
    private func tableBlock(headers: [String], alignments: [TableAlignment], rows: [[String]]) -> some View {
        let colCount = headers.count

        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                // Header
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        inlineMarkdown(headers[col])
                            .font(.carbonMono(.caption, weight: .semibold))
                            .foregroundStyle(Color.carbonAccent)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: tableSwiftUIAlignment(alignments, col))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.carbonAccent.opacity(0.08))
                    }
                }

                // Accent separator
                GridRow {
                    Color.carbonAccent.opacity(0.25)
                        .frame(height: 1)
                        .gridCellColumns(colCount)
                }

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    GridRow {
                        ForEach(0..<colCount, id: \.self) { col in
                            inlineMarkdown(col < row.count ? row[col] : "")
                                .font(.carbonMono(.caption))
                                .foregroundStyle(Color.carbonText.opacity(0.85))
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: tableSwiftUIAlignment(alignments, col))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(rowIdx.isMultiple(of: 2) ? Color.carbonCodeBg : Color.carbonSurface.opacity(0.4))
                        }
                    }
                }
            }
            .background(Color.carbonCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Carbon.radiusSmall)
                    .stroke(Color.carbonBorder.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func tableSwiftUIAlignment(_ alignments: [TableAlignment], _ col: Int) -> Alignment {
        guard col < alignments.count else { return .leading }
        switch alignments[col] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    // MARK: - Inline

    private func inlineMarkdown(_ text: String) -> Text {
        if let attributed = cachedAttributedString(for: text) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func standardCodeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    Text(language.uppercased())
                        .font(.carbonMono(.caption2, weight: .semibold))
                        .foregroundStyle(Color.carbonAccent.opacity(0.7))
                        .kerning(0.6)
                }
                Spacer()
                Button {
                    Haptics.copyToClipboard(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(Color.carbonTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

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

        | Model | Context | Price |
        |-------|:-------:|------:|
        | GPT-4 | 128K | $30/M |
        | Claude 3.5 | 200K | $15/M |
        | Gemini 1.5 | 1M | $7/M |

        [Link example](https://example.com)

        ```diff
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,5 +1,6 @@
         struct Foo {
             var name: String
        -    var age: Int
        +    var age: Int
        +    var email: String?
         
             init(name: String, age: Int) {
        -        self.name = name
        +        self.name = name.trimmed()
                 self.age = age
             }
        ```
        """)
        .padding()
    }
    .background(Color.carbonBlack)
    .preferredColorScheme(.dark)
}
