import Foundation

struct DiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]
}

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: Kind
    let content: String
    let oldLine: Int?
    let newLine: Int?

    enum Kind {
        case context
        case addition
        case deletion
        case hunkHeader
    }
}

struct DiffFileChange: Identifiable {
    let id = UUID()
    let filePath: String
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]

    var stats: String {
        if additions > 0 && deletions > 0 { return "+\(additions) / -\(deletions)" }
        if additions > 0 { return "+\(additions)" }
        if deletions > 0 { return "-\(deletions)" }
        return "no changes"
    }
}

enum DiffParser {
    static func parse(_ input: String) -> [DiffFileChange] {
        let lines = input.components(separatedBy: "\n")
        var changes: [DiffFileChange] = []
        var currentFilePath: String?
        var currentAdditions = 0
        var currentDeletions = 0
        var currentHunks: [DiffHunk] = []
        var hunkLines: [DiffLine] = []
        var hunkHeader = ""
        var inHunk = false

        func flushHunk() {
            guard !hunkLines.isEmpty || !hunkHeader.isEmpty else { return }
            currentHunks.append(DiffHunk(header: hunkHeader, lines: hunkLines))
            hunkLines = []
            hunkHeader = ""
            inHunk = false
        }

        func flushFile() {
            flushHunk()
            if let path = currentFilePath {
                changes.append(DiffFileChange(
                    filePath: path,
                    additions: currentAdditions,
                    deletions: currentDeletions,
                    hunks: currentHunks
                ))
            }
            currentFilePath = nil
            currentAdditions = 0
            currentDeletions = 0
            currentHunks = []
        }

        func filePath(from diffLine: String) -> String? {
            if diffLine.hasPrefix("+++ ") {
                let path = String(diffLine.dropFirst(4))
                    .trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("b/") { return String(path.dropFirst(2)) }
                if path.hasPrefix("/") { return path }
                return path
            }
            if diffLine.hasPrefix("--- ") {
                let path = String(diffLine.dropFirst(4))
                    .trimmingCharacters(in: .whitespaces)
                if path == "/dev/null" { return nil }
                if path.hasPrefix("a/") { return String(path.dropFirst(2)) }
                return path
            }
            return nil
        }

        var oldLineNum: Int?
        var newLineNum: Int?

        for line in lines {
            if line.hasPrefix("diff --git") {
                flushFile()
                if let range = line.range(of: " b/") {
                    currentFilePath = String(line[range.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if line.hasPrefix("--- ") {
                if currentFilePath == nil {
                    currentFilePath = filePath(from: line)
                }
                continue
            }

            if line.hasPrefix("+++ ") {
                let newPath = filePath(from: line)
                if let p = newPath, p != "/dev/null" {
                    currentFilePath = p
                }
                continue
            }

            if line.hasPrefix("@@") {
                flushHunk()
                hunkHeader = line
                inHunk = true
                let nums = parseHunkHeader(line)
                oldLineNum = nums.oldStart
                newLineNum = nums.newStart
                continue
            }

            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("Binary files") || line.hasPrefix("mode change") {
                continue
            }

            guard inHunk || currentFilePath != nil else { continue }

            if line.hasPrefix("+") {
                currentAdditions += 1
                let content = String(line.dropFirst())
                hunkLines.append(DiffLine(kind: .addition, content: content, oldLine: nil, newLine: newLineNum))
                if newLineNum != nil { newLineNum! += 1 }
            } else if line.hasPrefix("-") {
                currentDeletions += 1
                let content = String(line.dropFirst())
                hunkLines.append(DiffLine(kind: .deletion, content: content, oldLine: oldLineNum, newLine: nil))
                if oldLineNum != nil { oldLineNum! += 1 }
            } else if line.hasPrefix(" ") {
                let content = String(line.dropFirst())
                hunkLines.append(DiffLine(kind: .context, content: content, oldLine: oldLineNum, newLine: newLineNum))
                if oldLineNum != nil { oldLineNum! += 1 }
                if newLineNum != nil { newLineNum! += 1 }
            } else if line == "\\ No newline at end of file" {
                // skip
            } else if !line.isEmpty {
                hunkLines.append(DiffLine(kind: .context, content: line, oldLine: oldLineNum, newLine: newLineNum))
                if oldLineNum != nil { oldLineNum! += 1 }
                if newLineNum != nil { newLineNum! += 1 }
            }
        }

        flushFile()
        return changes
    }

    static func isDiffContent(_ text: String) -> Bool {
        text.contains("diff --git") || text.contains("\n---") || text.contains("\n+++")
            || text.contains("\n@@@") || text.contains("\n@@ ")
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int?, newStart: Int?) {
        // @@ -oldStart[,oldCount] +newStart[,newCount] @@
        var oldStart: Int?
        var newStart: Int?
        let parts = line.split(separator: " ")
        for part in parts {
            let s = String(part)
            if s.hasPrefix("-") {
                let numStr = s.dropFirst().split(separator: ",").first.flatMap(String.init) ?? ""
                oldStart = Int(numStr)
            } else if s.hasPrefix("+") {
                let numStr = s.dropFirst().split(separator: ",").first.flatMap(String.init) ?? ""
                newStart = Int(numStr)
            }
        }
        return (oldStart, newStart)
    }
}

import SwiftUI

struct DiffView: View {
    let changes: [DiffFileChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(changes) { change in
                DiffFileView(change: change)
            }
        }
    }
}

private struct DiffFileView: View {
    let change: DiffFileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonAccent)
                Text(change.filePath)
                    .font(.carbonMono(.caption, weight: .semibold))
                    .foregroundStyle(Color.carbonText)
                    .lineLimit(1)
                Spacer()
                Text(change.stats)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.carbonAccent.opacity(0.08))

            ForEach(change.hunks) { hunk in
                DiffHunkView(hunk: hunk)
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

private struct DiffHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hunk.header.isEmpty {
                Text(hunk.header)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonAccent.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.carbonAccent.opacity(0.04))
            }

            ForEach(hunk.lines) { line in
                DiffLineView(line: line)
            }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    private var bgColor: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.08)
        case .deletion: return Color.red.opacity(0.08)
        case .context: return .clear
        case .hunkHeader: return Color.carbonAccent.opacity(0.04)
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.9)
        case .deletion: return Color.red.opacity(0.85)
        case .context: return Color.carbonText.opacity(0.7)
        case .hunkHeader: return Color.carbonAccent.opacity(0.6)
        }
    }

    private var prefix: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        case .hunkHeader: return ""
        }
    }

    private var lineNumber: String {
        switch line.kind {
        case .addition: return line.newLine.map { "\($0)" } ?? ""
        case .deletion: return line.oldLine.map { "\($0)" } ?? ""
        case .context:
            let old = line.oldLine.map { "\($0)" } ?? ""
            let new = line.newLine.map { "\($0)" } ?? ""
            return old == new ? old : "\(old) \(new)"
        case .hunkHeader: return ""
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(lineNumber)
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary.opacity(0.5))
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 8)
            Text(prefix)
                .font(.carbonMono(.caption2))
                .bold()
                .foregroundStyle(textColor)
                .frame(width: 12, alignment: .center)
            Text(line.content)
                .font(.carbonMono(.caption2))
                .foregroundStyle(textColor)
                .lineLimit(nil)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(bgColor)
    }
}

struct DiffStatLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 {
                Text("+\(additions)")
                    .font(.carbonMono(.caption2, weight: .medium))
                    .foregroundStyle(Color.green.opacity(0.85))
            }
            if additions > 0 && deletions > 0 {
                Text("/")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .font(.carbonMono(.caption2, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.85))
            }
        }
    }
}