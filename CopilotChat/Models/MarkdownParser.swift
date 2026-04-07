import Foundation

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([(Int, String)])
    case blockquote(String)
    case horizontalRule

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

            // Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let pLine = lines[i]
                let pTrimmed = pLine.trimmingCharacters(in: .whitespaces)
                if pTrimmed.isEmpty || pTrimmed.hasPrefix("```") || pTrimmed.hasPrefix("#")
                    || pTrimmed.hasPrefix(">") || isUnorderedListItem(pTrimmed) || isOrderedListItem(pTrimmed) {
                    break
                }
                paraLines.append(pLine)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
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
}
