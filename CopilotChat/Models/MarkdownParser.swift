import Foundation
import Markdown

enum TableAlignment: Equatable {
    case left, center, right
}

enum MarkdownBlock: Equatable, Identifiable {
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([(Int, String)])
    case blockquote(String)
    case horizontalRule
    case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
    case taskList([(isComplete: Bool, text: String)])

    var id: String { debugId }

    var debugId: String {
        switch self {
        case .paragraph(let t): "p-\(t.prefix(50).hashValue)"
        case .codeBlock(let l, let c): "cb-\(l ?? "")-\(c.prefix(50).hashValue)"
        case .heading(let l, let t): "h\(l)-\(t.prefix(50).hashValue)"
        case .unorderedList(let items): "ul-\(items.count)-\(items.first?.prefix(20).hashValue ?? 0)"
        case .orderedList(let items): "ol-\(items.count)-\(items.first?.1.prefix(20).hashValue ?? 0)"
        case .blockquote(let t): "bq-\(t.prefix(50).hashValue)"
        case .horizontalRule: "hr"
        case .table(let h, _, _): "tbl-\(h.joined(separator: "|").hashValue)"
        case .taskList(let items): "tl-\(items.count)-\(items.first?.text.prefix(20).hashValue ?? 0)"
        }
    }

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        switch (lhs, rhs) {
        case (.paragraph(let a), .paragraph(let b)): a == b
        case (.codeBlock(let la, let ca), .codeBlock(let lb, let cb)): la == lb && ca == cb
        case (.heading(let la, let ta), .heading(let lb, let tb)): la == lb && ta == tb
        case (.unorderedList(let a), .unorderedList(let b)): a == b
        case (.orderedList(let a), .orderedList(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.blockquote(let a), .blockquote(let b)): a == b
        case (.horizontalRule, .horizontalRule): true
        case (.table(let ha, let aa, let ra), .table(let hb, let ab, let rb)):
            ha == hb && aa == ab && ra == rb
        case (.taskList(let a), .taskList(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.isComplete == $1.isComplete && $0.text == $1.text }
        default: false
        }
    }
}

enum MarkdownParser {
    static func parse(_ input: String) -> [MarkdownBlock] {
        let document = Document(parsing: input)
        var walker = BlockWalker()
        walker.visit(document)
        return walker.blocks
    }

    static func splitTableRow(_ line: String) -> [String] {
        var result = line.split(separator: Character("|"), omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if result.first?.isEmpty == true { result.removeFirst() }
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    static func isTableSeparator(_ line: String) -> Bool {
        parseTableSeparator(line) != nil
    }

    static func parseTableSeparator(_ line: String) -> [TableAlignment]? {
        guard line.hasPrefix("|") else { return nil }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            guard !cell.isEmpty else { return nil }
            let hasLeft = cell.hasPrefix(":")
            let hasRight = cell.hasSuffix(":")
            let stripped = hasLeft ? String(cell.dropFirst()) : cell
            let stripped2 = stripped.hasSuffix(":") ? String(stripped.dropLast()) : stripped
            guard !stripped2.isEmpty, stripped2.allSatisfy({ $0 == "-" }) else { return nil }
            if hasLeft && hasRight { alignments.append(.center) }
            else if hasRight { alignments.append(.right) }
            else { alignments.append(.left) }
        }
        return alignments
    }

    static func isUnorderedListItem(_ line: String) -> Bool {
        guard let first = line.first, (first == "-" || first == "*" || first == "+") else { return false }
        return line.count > 1 && line[line.index(after: line.startIndex)] == " "
    }

    static func stripUnorderedPrefix(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, (first == "-" || first == "*" || first == "+"),
              trimmed.count > 1 else { return String(line) }
        return String(trimmed.dropFirst(2))
    }

    static func isOrderedListItem(_ line: String) -> Bool {
        var idx = line.startIndex
        guard idx < line.endIndex, line[idx].isNumber else { return false }
        while idx < line.endIndex && line[idx].isNumber { idx = line.index(after: idx) }
        guard idx < line.endIndex, line[idx] == "." else { return false }
        idx = line.index(after: idx)
        return idx < line.endIndex && line[idx] == " "
    }

    static func stripOrderedPrefix(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let dotIdx = trimmed.firstIndex(of: ".") else { return String(line) }
        let afterDot = trimmed.index(after: dotIdx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return String(line) }
        return String(trimmed[trimmed.index(after: afterDot)...])
    }

    static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level else { return nil }
        let rest = line[line.index(line.startIndex, offsetBy: level)...]
        guard rest.hasPrefix(" ") else { return nil }
        return (level, String(rest.dropFirst()))
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let chars = Set(line)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }
}

private struct BlockWalker: MarkupWalker {
    var blocks: [MarkdownBlock] = []

    private func plainText(_ markup: some Markup) -> String {
        var collector = InlineTextCollector()
        collector.visit(markup)
        return collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func visitHeading(_ heading: Heading) {
        let text = plainText(heading)
        blocks.append(.heading(level: heading.level, text: text))
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        if let parent = paragraph.parent,
           parent is BlockQuote {
            return
        }
        let text = plainText(paragraph)
        guard !text.isEmpty else { return }
        blocks.append(.paragraph(text))
    }

    mutating func visitCodeBlock(_ codeBlock: Markdown.CodeBlock) {
        let language = codeBlock.language ?? ""
        let code = String(codeBlock.code).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: code))
    }

    mutating func visitUnorderedList(_ unorderedList: Markdown.UnorderedList) {
        var items: [String] = []
        for child in unorderedList.listItems {
            let text = plainText(child)
            if let checkbox = child.checkbox {
                let checked = checkbox == .checked
                blocks.append(.taskList([(isComplete: checked, text: text)]))
                continue
            }
            items.append(text)
        }
        if !items.isEmpty {
            blocks.append(.unorderedList(items))
        }
    }

    mutating func visitOrderedList(_ orderedList: Markdown.OrderedList) {
        var items: [(Int, String)] = []
        var number = Int(orderedList.startIndex)
        for child in orderedList.listItems {
            let text = plainText(child)
            items.append((number, text))
            number += 1
        }
        blocks.append(.orderedList(items))
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let text = plainText(blockQuote)
        blocks.append(.blockquote(text))
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        blocks.append(.horizontalRule)
    }

    mutating func visitTable(_ table: Markdown.Table) {
        var headers: [String] = []
        var alignments: [TableAlignment] = []

        for cell in table.head.cells {
            headers.append(plainText(cell))
            if let col = table.columnAlignments[safe: headers.count - 1] {
                switch col {
                case .center: alignments.append(.center)
                case .right: alignments.append(.right)
                default: alignments.append(.left)
                }
            } else {
                alignments.append(.left)
            }
        }

        var rows: [[String]] = []
        for row in table.body.rows {
            var cells: [String] = []
            for cell in row.cells {
                cells.append(plainText(cell))
            }
            rows.append(cells)
        }

        blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
    }

    mutating func visitListItem(_ listItem: Markdown.ListItem) {
        // Skip — list items are handled in visitUnorderedList/visitOrderedList
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        // handled within plainText
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        // handled within plainText
    }

    mutating func visitText(_ text: Markdown.Text) {
        // handled within plainText
    }

    mutating func visitStrong(_ strong: Strong) {
        // handled within plainText
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        // handled within plainText
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        // handled within plainText
    }

    mutating func visitLink(_ link: Markdown.Link) {
        // handled within plainText
    }

    mutating func visitImage(_ image: Markdown.Image) {
        // handled within plainText
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        // handled within plainText
    }
}

private struct InlineTextCollector: MarkupWalker {
    var text = ""

    mutating func visitText(_ text: Markdown.Text) {
        self.text += text.string
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        text += " "
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        text += "\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        text += "`\(inlineCode.code)`"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        text += "~~"
        for child in strikethrough.children {
            visit(child)
        }
        text += "~~"
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}