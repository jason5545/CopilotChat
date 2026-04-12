import Foundation

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
        default: false
        }
    }
}

enum MarkdownParser {
    static func parse(_ input: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.0, text: heading.1))
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Unordered list
            if isUnorderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count, isUnorderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripUnorderedPrefix(lines[i]))
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list
            if isOrderedListItem(trimmed) {
                var items: [(Int, String)] = []
                var num = 1
                while i < lines.count, isOrderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append((num, stripOrderedPrefix(lines[i])))
                    num += 1
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = lines[i]
                    if let idx = content.firstIndex(of: ">") {
                        content = String(content[content.index(after: idx)...])
                        if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                    }
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Table
            if isTableStart(lines, at: i) {
                let headers = splitTableRow(trimmed)
                let sepLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let alignments = parseTableSeparator(sepLine)!  // safe: isTableStart validated
                i += 2
                var dataRows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    dataRows.append(splitTableRow(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: dataRows))
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let pTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if pTrimmed.isEmpty || pTrimmed.hasPrefix("```") || pTrimmed.hasPrefix("#")
                    || pTrimmed.hasPrefix(">") || isHorizontalRule(pTrimmed)
                    || isUnorderedListItem(pTrimmed) || isOrderedListItem(pTrimmed)
                    || (pTrimmed.hasPrefix("|") && isTableStart(lines, at: i)) {
                    break
                }
                paraLines.append(pTrimmed)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    // MARK: - Line Classifiers

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

    // MARK: - Table Helpers

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

    /// Validates separator and returns alignments in one pass (single `splitTableRow`).
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

    static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), index + 1 < lines.count else { return false }
        return parseTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) != nil
    }
}
