import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - FileSystemPlugin

@MainActor
final class FileSystemPlugin: Plugin {
    let id = "com.copilotchat.filesystem"
    let name = "FileSystem"
    let version = "1.0.0"

    func configure(with input: PluginInput) async throws -> PluginHooks {
        let tools = [
            MCPTool(
                name: "list_files",
                description: "List files and folders in a directory. Returns names, sizes, modification dates, and file type indicators. Supports recursive listing.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The directory path to list. Use \".\" for the root workspace directory.",
                        ] as [String: Any],
                        "recursive": [
                            "type": "boolean",
                            "description": "List files recursively into subdirectories. Default: false.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "read_file",
                description: "Read the contents of a text file. Returns the file contents with line numbers. Supports reading a range of lines via offset and limit.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The path to the file to read.",
                        ] as [String: Any],
                        "offset": [
                            "type": "integer",
                            "description": "Line number to start reading from (1-indexed). Default: 1.",
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of lines to return. Default: 2000.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "write_file",
                description: "Write or overwrite contents to a text file. Creates the file if it doesn't exist.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The full path to the file to write.",
                        ] as [String: Any],
                        "content": [
                            "type": "string",
                            "description": "The text content to write to the file.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path", "content"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "edit_file",
                description: "Edit an existing text file by replacing exact text. By default the old text must match exactly once; set replace_all to true to replace every match.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The full path to the file to edit.",
                        ] as [String: Any],
                        "old_text": [
                            "type": "string",
                            "description": "Exact text to find in the file.",
                        ] as [String: Any],
                        "new_text": [
                            "type": "string",
                            "description": "Replacement text.",
                        ] as [String: Any],
                        "replace_all": [
                            "type": "boolean",
                            "description": "Replace all matches instead of requiring exactly one match.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path", "old_text", "new_text"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "create_file",
                description: "Create a new file at the specified path. Optionally provide initial content. Creates intermediate directories if needed.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The path for the new file.",
                        ] as [String: Any],
                        "content": [
                            "type": "string",
                            "description": "Optional initial content to write to the file.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "delete_file",
                description: "Delete a file or empty directory at the specified path.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The path to the file or empty directory to delete.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "move_file",
                description: "Move or rename a file or directory. Creates destination parent directories if needed. If destination is an existing directory, moves source into it.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "source": [
                            "type": "string",
                            "description": "The current path of the file or directory.",
                        ] as [String: Any],
                        "destination": [
                            "type": "string",
                            "description": "The destination path. If it names an existing directory, the source is moved inside it.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["source", "destination"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "grep_files",
                description: "Fast content search across the workspace using regex. Returns file paths, line numbers, and matching lines with optional context. Supports file filtering and directory exclusion.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "pattern": [
                            "type": "string",
                            "description": "The regex pattern to search for in file contents.",
                        ] as [String: Any],
                        "path": [
                            "type": "string",
                            "description": "The directory path to search in. Use \".\" for the workspace root.",
                        ] as [String: Any],
                        "include": [
                            "type": "string",
                            "description": "File pattern to include (e.g. \"*.swift\", \"*.tsx\", \"*.{ts,tsx}\", \"Makefile\"). Supports simple globs.",
                        ] as [String: Any],
                        "case_insensitive": [
                            "type": "boolean",
                            "description": "Perform case-insensitive search. Default: false.",
                        ] as [String: Any],
                        "context_lines": [
                            "type": "integer",
                            "description": "Number of context lines to show before and after each match. Default: 0.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["pattern"]),
                ],
                serverName: name
            ),
        ]

        return PluginHooks(tools: tools) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        let workspaceManager = WorkspaceManager.shared

        guard workspaceManager.hasWorkspace else {
            return ToolResult(text: "No workspace selected. Please select a project folder first.")
        }

        switch name {
        case "list_files":
            return workspaceManager.listFiles(argumentsJSON: argumentsJSON)
        case "read_file":
            return workspaceManager.readFile(argumentsJSON: argumentsJSON)
        case "write_file":
            return workspaceManager.writeFile(argumentsJSON: argumentsJSON)
        case "edit_file":
            return workspaceManager.editFile(argumentsJSON: argumentsJSON)
        case "create_file":
            return workspaceManager.createFile(argumentsJSON: argumentsJSON)
        case "delete_file":
            return workspaceManager.deleteFile(argumentsJSON: argumentsJSON)
        case "move_file":
            return workspaceManager.moveFile(argumentsJSON: argumentsJSON)
        case "grep_files":
            return try await workspaceManager.grepFiles(argumentsJSON: argumentsJSON)
        default:
            throw PluginRegistry.PluginError.unknownTool(name)
        }
    }
}

// MARK: - WorkspaceManager

@MainActor
final class WorkspaceManager: NSObject, @unchecked Sendable {
    static let shared = WorkspaceManager()

    var hasWorkspace: Bool { _currentURL != nil }
    var currentURL: URL? { _currentURL }
    var workspaceName: String? { _workspaceName }
    var isAccessing: Bool { _isAccessing }
    var isICloudWorkspace: Bool { _isICloudWorkspace }

    private var _currentURL: URL?
    private var _workspaceName: String?
    private var _isAccessing: Bool = false
    private var _isICloudWorkspace: Bool = false

    private var _trackedHasWorkspace: Bool = false
    var trackedHasWorkspace: Bool {
        _trackedHasWorkspace
    }

    private var _trackedWorkspaceName: String?
    var trackedWorkspaceName: String? {
        _trackedWorkspaceName
    }

    private let bookmarkKey = "FileSystemPlugin.workspaceBookmark"

    private override init() {
        super.init()
        restoreWorkspace()
    }

    func selectWorkspace(from viewController: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        viewController.present(picker, animated: true)
    }

    func clearWorkspace() {
        if _isAccessing {
            _currentURL?.stopAccessingSecurityScopedResource()
        }
        _currentURL = nil
        _workspaceName = nil
        _isAccessing = false
        _isICloudWorkspace = false
        _trackedHasWorkspace = false
        _trackedWorkspaceName = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private func saveBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
    }

    private func restoreWorkspace() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                try? saveBookmark(for: url)
            }

            if url.startAccessingSecurityScopedResource() {
                updateWorkspaceState(for: url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    private func updateWorkspaceState(for url: URL) {
        _currentURL = url
        _workspaceName = url.lastPathComponent
        _isAccessing = true
        _isICloudWorkspace = isICloudDirectory(url)
        _trackedHasWorkspace = true
        _trackedWorkspaceName = url.lastPathComponent
    }

    private func isICloudDirectory(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey]
        let values = try? url.resourceValues(forKeys: keys)
        return values?.isUbiquitousItem ?? false
    }

    private func resolvePath(_ path: String) -> URL? {
        guard let rootURL = _currentURL else { return nil }

        if path == "." {
            return rootURL
        }

        if path.hasPrefix("/") {
            return rootURL.appendingPathComponent(String(path.dropFirst()))
        }

        return rootURL.appendingPathComponent(path)
    }

    private func coordinatedRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        if !_isICloudWorkspace {
            return try accessor(url)
        }

        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw FileSystemPluginError.operationFailed("File coordination failed during read")
        }
        return try result.get()
    }

    private func coordinatedWrite<T>(accessor: () throws -> T) throws -> T {
        if !_isICloudWorkspace {
            return try accessor()
        }

        guard let workspaceURL = _currentURL else {
            throw FileSystemPluginError.operationFailed("Workspace not accessible")
        }

        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(writingItemAt: workspaceURL, options: [], error: &coordinationError) { _ in
            result = Result { try accessor() }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw FileSystemPluginError.operationFailed("File coordination failed during write")
        }
        return try result.get()
    }

    func resolvePathPublic(_ path: String) -> URL? {
        resolvePath(path)
    }

    func listFiles(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let path: String
        let recursive: Bool
        do {
            path = try parseArgument(argumentsJSON, key: "path", defaultValue: ".")
            recursive = parseBoolArgument(argumentsJSON, key: "recursive", defaultValue: false)
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let maxEntries = 500
        let skipDirs: Set<String> = [
            ".git", ".svn", ".hg", "node_modules", "build", "DerivedData",
            ".build", "Pods", ".gradle", ".cache", ".cargo", "target",
            "__pycache__", ".venv", "dist", "out",
        ]

        var lines: [String] = []
        var dirCount = 0
        var fileCount = 0

        do {
            if recursive {
                guard let enumerator = FileManager.default.enumerator(
                    at: targetURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    return ToolResult(text: "Cannot enumerate directory: \(path)")
                }

                for case let fileURL as URL in enumerator {
                    guard lines.count < maxEntries else { break }

                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { continue }

                    if isDir.boolValue {
                        if skipDirs.contains(fileURL.lastPathComponent) {
                            enumerator.skipDescendants()
                            continue
                        }
                        dirCount += 1
                    } else {
                        fileCount += 1
                    }

                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDirectory = isDir.boolValue
                    let size = resourceValues?.fileSize ?? 0

                    let relativePath: String
                    if let root = _currentURL {
                        relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
                    } else {
                        relativePath = fileURL.lastPathComponent
                    }

                    if isDirectory {
                        lines.append("  DIR  \(relativePath)/")
                    } else {
                        let sizeStr = size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : "0 B"
                        lines.append("  \(sizeStr)  \(relativePath)")
                    }
                }
            } else {
                let contents = try coordinatedRead(at: targetURL) { coordinatedURL in
                    try FileManager.default.contentsOfDirectory(
                        at: coordinatedURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                }

                for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    let isDir = resourceValues.isDirectory ?? false
                    let size = resourceValues.fileSize ?? 0
                    let date = resourceValues.contentModificationDate ?? Date.distantPast
                    let dateStr = dateFormatter.string(from: date)

                    if isDir {
                        dirCount += 1
                        lines.append("\(dateStr)  DIR  \(fileURL.lastPathComponent)/")
                    } else {
                        fileCount += 1
                        let sizeStr = size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : "0 B"
                        lines.append("\(dateStr)  \(sizeStr)  \(fileURL.lastPathComponent)")
                    }
                }
            }

            if lines.isEmpty {
                return ToolResult(text: "(empty directory)")
            }

            var footer = ""
            footer += "\n\(dirCount) directories, \(fileCount) files"
            if lines.count >= maxEntries {
                footer += " (output truncated at \(maxEntries) entries)"
            }

            return ToolResult(text: "Contents of \(path):\n" + lines.joined(separator: "\n") + footer)
        } catch {
            return ToolResult(text: "Error listing directory: \(error.localizedDescription)")
        }
    }

    func readFile(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let path: String
        let offset: Int
        let limit: Int
        do {
            path = try parseArgument(argumentsJSON, key: "path")
            offset = parseIntArgument(argumentsJSON, key: "offset", defaultValue: 1)
            limit = parseIntArgument(argumentsJSON, key: "limit", defaultValue: 2000)
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        do {
            let content = try coordinatedRead(at: targetURL) { coordinatedURL -> String in
                let attrs = try FileManager.default.attributesOfItem(atPath: coordinatedURL.path)
                let fileSize = attrs[.size] as? Int ?? 0
                if fileSize > 10_000_000 {
                    throw FileSystemPluginError.operationFailed("File too large to read (\(fileSize) bytes). Use grep_files to search within it.")
                }
                guard let s = try? String(contentsOf: coordinatedURL, encoding: .utf8) else {
                    throw FileSystemPluginError.operationFailed("File is not valid UTF-8 text")
                }
                return s
            }

            let allLines = content.components(separatedBy: .newlines)
            let totalLines = allLines.count
            let startLine = max(1, offset)
            let endLine = min(totalLines, startLine + limit - 1)

            guard startLine <= totalLines else {
                return ToolResult(text: "File has \(totalLines) lines, requested offset \(startLine) is out of range.")
            }

            var numberedLines: [String] = []
            for i in startLine...endLine {
                numberedLines.append("\(i): \(allLines[i - 1])")
            }

            var header = ""
            if startLine > 1 || endLine < totalLines {
                header = "(lines \(startLine)-\(endLine) of \(totalLines))\n"
            }

            return ToolResult(text: header + numberedLines.joined(separator: "\n"))
        } catch {
            return ToolResult(text: "Error reading file: \(error.localizedDescription)")
        }
    }

    func writeFile(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let path: String
        let content: String
        do {
            path = try parseArgument(argumentsJSON, key: "path")
            content = try parseArgument(argumentsJSON, key: "content")
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        do {
            try coordinatedWrite {
                let parentDir = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
                    throw FileSystemPluginError.invalidArguments("Path is a directory, not a file: \(path)")
                }

                guard let data = content.data(using: .utf8) else {
                    throw FileSystemPluginError.operationFailed("Content is not valid UTF-8")
                }
                try data.write(to: targetURL, options: .atomic)
            }
            let lineCount = content.components(separatedBy: .newlines).count
            return ToolResult(text: "Wrote \(lineCount) lines to \(path)")
        } catch {
            return ToolResult(text: "Error writing file: \(error.localizedDescription)")
        }
    }

    func editFile(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let path: String
        let oldText: String
        let newText: String
        let replaceAll: Bool
        do {
            path = try parseArgument(argumentsJSON, key: "path")
            oldText = try parseArgument(argumentsJSON, key: "old_text")
            newText = try parseArgument(argumentsJSON, key: "new_text")
            replaceAll = parseBoolArgument(argumentsJSON, key: "replace_all", defaultValue: false)
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        let original: String
        do {
            original = try coordinatedRead(at: targetURL) { coordinatedURL in
                let originalData = try Data(contentsOf: coordinatedURL)
                guard let original = String(data: originalData, encoding: .utf8) else {
                    throw FileSystemPluginError.operationFailed("File is not valid UTF-8")
                }
                return original
            }
        } catch {
            return ToolResult(text: "Error reading file for edit: \(path)")
        }

        let matchCount: Int
        if oldText.isEmpty {
            matchCount = 0
        } else {
            matchCount = original.components(separatedBy: oldText).count - 1
        }
        guard matchCount > 0 else {
            return ToolResult(text: "Edit failed: old_text not found in \(path)")
        }

        if !replaceAll && matchCount != 1 {
            return ToolResult(text: "Edit failed: old_text matched \(matchCount) times in \(path). Use replace_all to replace every match.")
        }

        let updated = replaceAll
            ? original.replacingOccurrences(of: oldText, with: newText)
            : original.replacingOccurrences(of: oldText, with: newText, options: [], range: original.range(of: oldText)!)

        guard let updatedData = updated.data(using: .utf8) else {
            return ToolResult(text: "Error editing file: updated content is not valid UTF-8")
        }

        do {
            try coordinatedWrite {
                try updatedData.write(to: targetURL, options: .atomic)
            }
            let originalLines = original.components(separatedBy: .newlines).count
            let updatedLines = updated.components(separatedBy: .newlines).count
            let lineDelta = updatedLines - originalLines
            let deltaStr = lineDelta == 0 ? "no line count change" : lineDelta > 0 ? "+\(lineDelta) lines" : "\(lineDelta) lines"
            let action = replaceAll ? "Replaced \(matchCount) occurrences" : "Replaced 1 occurrence"
            let diff = generateUnifiedDiff(path: path, oldText: original, newText: updated)
            return ToolResult(text: "\(action) in \(path) (\(originalLines) → \(updatedLines) lines, \(deltaStr))\n\n\(diff)")
        } catch {
            return ToolResult(text: "Error editing file: \(error.localizedDescription)")
        }
    }

    private func generateUnifiedDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        var out: [String] = ["diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)"]

        // Simple longest-common-subsequence diff
        let ops = lcsEditOps(old: oldLines, new: newLines)
        let hunks = groupIntoHunks(ops: ops, context: 3)
        guard !hunks.isEmpty else { return "" }

        for h in hunks {
            var lines: [String] = []
            for op in h.ops {
                switch op {
                case .equal(let oi, let ni): lines.append(" \(oldLines[oi])")
                case .delete(let oi): lines.append("-\(oldLines[oi])")
                case .insert(let ni): lines.append("+\(newLines[ni])")
                }
            }
            out.append("@@ -\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) @@")
            out.append(contentsOf: lines)
        }
        return out.joined(separator: "\n")
    }

    private enum Edit { case equal(oldIdx: Int, newIdx: Int); case delete(oldIdx: Int); case insert(newIdx: Int) }

    private struct HunkInfo { var oldStart: Int; var oldCount: Int; var newStart: Int; var newCount: Int; var ops: [Edit] }

    private func lcsEditOps(old: [String], new: [String]) -> [Edit] {
        let m = old.count, n = new.count
        if m == 0 { return new.enumerated().map { .insert(newIdx: $0.offset) } }
        if n == 0 { return old.enumerated().map { .delete(oldIdx: $0.offset) } }

        // Use patience/LCS approach via DP for small files, hash-based for large
        if m * n <= 4_000_000 {
            return lcsDP(old: old, new: new)
        }
        return lcsDP(old: old, new: new)
    }

    private func lcsDP(old: [String], new: [String]) -> [Edit] {
        let m = old.count, n = new.count
        // DP table storing LCS length
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if old[i-1] == new[j-1] { dp[i][j] = dp[i-1][j-1] + 1 }
                else { dp[i][j] = Swift.max(dp[i-1][j], dp[i][j-1]) }
            }
        }
        // Backtrack to get edit operations
        var edits: [Edit] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && old[i-1] == new[j-1] {
                edits.append(.equal(oldIdx: i-1, newIdx: j-1))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                edits.append(.insert(newIdx: j-1))
                j -= 1
            } else {
                edits.append(.delete(oldIdx: i-1))
                i -= 1
            }
        }
        return edits.reversed()
    }

    private func groupIntoHunks(ops: [Edit], context: Int) -> [HunkInfo] {
        var hunks: [HunkInfo] = []
        var i = 0
        while i < ops.count {
            let isChange: Bool
            switch ops[i] { case .delete(_), .insert(_:): isChange = true; default: isChange = false }
            guard isChange else { i += 1; continue }

            let changeStart = i
            var changeEnd = i
            while changeEnd < ops.count {
                let eIsChange: Bool
                switch ops[changeEnd] { case .delete(_), .insert(_:): eIsChange = true; default: eIsChange = false }
                if eIsChange { changeEnd += 1; continue }
                var equalRun = 0, j = changeEnd
                while j < ops.count {
                    if case .equal(_) = ops[j] { equalRun += 1; j += 1 } else { break }
                }
                if equalRun > context * 2 { break }
                changeEnd = j
            }

            let from = Swift.max(0, changeStart - context)
            let to = Swift.min(ops.count - 1, changeEnd + context - 1)
            let hunkOps = Array(ops[from...to])

            var oldStart = 0, newStart = 0
            var oldCount = 0, newCount = 0
            for op in hunkOps {
                switch op {
                case .equal(let oi, let ni):
                    if oldStart == 0 { oldStart = oi + 1; newStart = ni + 1 }
                    oldCount += 1; newCount += 1
                case .delete(let oi):
                    if oldStart == 0 { oldStart = oi + 1 }
                    oldCount += 1
                case .insert(let ni):
                    if newStart == 0 { newStart = ni + 1 }
                    newCount += 1
                }
            }
            if oldStart == 0 { oldStart = 1 }; if newStart == 0 { newStart = 1 }
            hunks.append(HunkInfo(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, ops: hunkOps))
            i = to + 1
        }
        return hunks
    }

    func createFile(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let path: String
        let content: String?
        do {
            path = try parseArgument(argumentsJSON, key: "path")
            content = try? parseArgument(argumentsJSON, key: "content", defaultValue: nil)
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        do {
            try coordinatedWrite {
                let parentDir = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        throw FileSystemPluginError.invalidArguments("Path already exists as a directory: \(path)")
                    }
                    throw FileSystemPluginError.invalidArguments("File already exists: \(path)")
                }

                let data = content?.data(using: .utf8) ?? Data()
                FileManager.default.createFile(atPath: targetURL.path, contents: data)
            }
            return ToolResult(text: "Created \(path)")
        } catch {
            return ToolResult(text: "Error creating file: \(error.localizedDescription)")
        }
    }

    func deleteFile(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let path: String
        do {
            path = try parseArgument(argumentsJSON, key: "path")
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            return ToolResult(text: "Path does not exist: \(path)")
        }

        do {
            try coordinatedWrite {
                try FileManager.default.removeItem(at: targetURL)
            }
            if isDir.boolValue {
                return ToolResult(text: "Deleted directory \(path)")
            } else {
                return ToolResult(text: "Deleted file \(path)")
            }
        } catch {
            return ToolResult(text: "Error deleting: \(error.localizedDescription)")
        }
    }

    func moveFile(argumentsJSON: String) -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let source: String
        let destination: String
        do {
            source = try parseArgument(argumentsJSON, key: "source")
            destination = try parseArgument(argumentsJSON, key: "destination")
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let sourceURL = resolvePath(source) else {
            return ToolResult(text: "Invalid source path: \(source)")
        }

        guard var destURL = resolvePath(destination) else {
            return ToolResult(text: "Invalid destination path: \(destination)")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            return ToolResult(text: "Source does not exist: \(source)")
        }

        do {
            try coordinatedWrite {
                var destIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: destURL.path, isDirectory: &destIsDir), destIsDir.boolValue {
                    destURL = destURL.appendingPathComponent(sourceURL.lastPathComponent)
                }

                let parentDir = destURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                if FileManager.default.fileExists(atPath: destURL.path) {
                    throw FileSystemPluginError.invalidArguments("Destination already exists: \(destURL.lastPathComponent)")
                }

                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            }
            let typeStr = isDir.boolValue ? "directory" : "file"
            return ToolResult(text: "Moved \(typeStr) \(source) → \(destination)")
        } catch {
            return ToolResult(text: "Error moving: \(error.localizedDescription)")
        }
    }

    func grepFiles(argumentsJSON: String) async throws -> ToolResult {
        guard _currentURL != nil, _isAccessing else {
            return ToolResult(text: "Workspace not accessible")
        }

        let pattern: String
        let path: String
        let include: String?
        let caseInsensitive: Bool
        let contextLines: Int
        do {
            pattern = try parseArgument(argumentsJSON, key: "pattern")
            path = try parseArgument(argumentsJSON, key: "path", defaultValue: ".")
            include = try? parseArgument(argumentsJSON, key: "include", defaultValue: nil)
            caseInsensitive = parseBoolArgument(argumentsJSON, key: "case_insensitive", defaultValue: false)
            contextLines = parseIntArgument(argumentsJSON, key: "context_lines", defaultValue: 0)
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let searchURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        let regexOptions: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
        } catch {
            return ToolResult(text: "Invalid regex pattern: \(error.localizedDescription)")
        }

        let fileFilter = parseIncludePattern(include)
        let skipDirs: Set<String> = [
            ".git", ".svn", ".hg",
            "node_modules", ".npm", ".yarn", ".pnpm-store",
            "build", "DerivedData", ".build", ".gradle",
            "Pods", ".spm-build",
            ".cache", ".cargo", "target",
            "__pycache__", ".venv", "venv",
            ".next", ".nuxt", "dist", "out",
        ]
        let maxOutputLines = 200
        let maxMatchesPerFile = 20

        var outputLines: [String] = []
        var totalMatches = 0
        var matchedFiles = 0
        var truncatedFiles = 0

        func searchDirectory(_ dirURL: URL) {
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let fileURL as URL in enumerator {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { continue }

                if isDir.boolValue {
                    if skipDirs.contains(fileURL.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if !matchesFileFilter(fileURL.lastPathComponent, filter: fileFilter) {
                    continue
                }

                guard let data = try? Data(contentsOf: fileURL),
                      !isLikelyBinary(data),
                      let content = String(data: data, encoding: .utf8) else { continue }

                let nsContent = content as NSString
                let fullRange = NSRange(location: 0, length: nsContent.length)
                let matches = regex.matches(in: content as String, options: [], range: fullRange)
                guard !matches.isEmpty else { continue }

                matchedFiles += 1
                let totalFileMatches = matches.count
                totalMatches += totalFileMatches

                let relativePath: String
                if let root = _currentURL {
                    relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
                } else {
                    relativePath = fileURL.lastPathComponent
                }

                let limitedMatches = Array(matches.prefix(maxMatchesPerFile))
                if totalFileMatches > maxMatchesPerFile {
                    truncatedFiles += 1
                }

                let allLines = content.components(separatedBy: .newlines)

                for match in limitedMatches {
                    guard outputLines.count < maxOutputLines else { break }

                    let lineRange = nsContent.lineRange(for: match.range)
                    let lineNumber = nsContent.substring(with: NSRange(location: 0, length: lineRange.lowerBound))
                        .components(separatedBy: .newlines).count
                    let lineText = nsContent.substring(with: lineRange).trimmingCharacters(in: .newlines)
                    outputLines.append("\(relativePath):\(lineNumber): \(lineText)")

                    if contextLines > 0 {
                        let contextStart = max(1, lineNumber - contextLines)
                        let contextEnd = min(allLines.count, lineNumber + contextLines)
                        for ctxLineNum in contextStart...contextEnd where ctxLineNum != lineNumber {
                            guard outputLines.count < maxOutputLines else { break }
                            let ctxText = allLines[ctxLineNum - 1]
                            outputLines.append("\(relativePath):\(ctxLineNum)- \(ctxText)")
                        }
                    }
                }

                if outputLines.count >= maxOutputLines { break }
            }
        }

        try? coordinatedRead(at: searchURL) { coordinatedURL in
            searchDirectory(coordinatedURL)
        }

        if outputLines.isEmpty {
            return ToolResult(text: "No matches found for pattern: \(pattern)")
        }

        var footer = ""
        if totalMatches > outputLines.filter({ $0.contains(":") && !$0.contains("- ") }).count || matchedFiles > 1 {
            footer += "\n\n\(totalMatches) matches across \(matchedFiles) files"
        }
        if outputLines.count >= maxOutputLines {
            footer += " (output truncated at \(maxOutputLines) lines)"
        }
        if truncatedFiles > 0 {
            footer += " (\(truncatedFiles) files had additional matches not shown)"
        }

        return ToolResult(text: outputLines.joined(separator: "\n") + footer)
    }

    private func isLikelyBinary(_ data: Data) -> Bool {
        let checkSize = min(data.count, 8192)
        guard checkSize > 0 else { return false }
        let slice = data.prefix(checkSize)
        var nonTextCount = 0
        for byte in slice {
            if byte == 0 { return true }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                nonTextCount += 1
            }
        }
        return Double(nonTextCount) / Double(checkSize) > 0.3
    }

    private enum FileFilter {
        case any
        case extensions([String])
        case nameExact(String)
        case namePrefix(String)
        case nameSuffix(String)
    }

    private func parseIncludePattern(_ pattern: String?) -> FileFilter {
        guard let pattern, !pattern.isEmpty else { return .any }

        if pattern.hasPrefix("*.{") && pattern.hasSuffix("}") {
            let inner = String(pattern.dropFirst(3).dropLast())
            let exts = inner.split(separator: ",").flatMap { raw -> [String] in
                let part = raw.trimmingCharacters(in: .whitespaces)
                if part.hasPrefix("*.") {
                    return [String(part.dropFirst(2)).lowercased()]
                }
                return [part.lowercased()]
            }
            return .extensions(exts)
        }
        if pattern.hasPrefix("*.") {
            return .extensions([String(pattern.dropFirst(2)).lowercased()])
        }
        if pattern.hasPrefix("*") {
            return .nameSuffix(String(pattern.dropFirst()).lowercased())
        }
        if pattern.hasSuffix("*") {
            return .namePrefix(String(pattern.dropLast()).lowercased())
        }
        if !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[") {
            return .nameExact(pattern)
        }
        return .any
    }

    private func matchesFileFilter(_ filename: String, filter: FileFilter) -> Bool {
        switch filter {
        case .any:
            return true
        case .extensions(let exts):
            let ext = (filename as NSString).pathExtension.lowercased()
            return !ext.isEmpty && exts.contains(ext)
        case .nameExact(let name):
            return filename == name
        case .namePrefix(let prefix):
            return filename.lowercased().hasPrefix(prefix)
        case .nameSuffix(let suffix):
            return filename.lowercased().hasSuffix(suffix)
        }
    }

    private func parseArgument(_ json: String, key: String, defaultValue: String? = nil) throws -> String {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = args[key] as? String else {
            if let defaultValue {
                return defaultValue
            }
            throw FileSystemPluginError.invalidArguments("Missing or invalid '\(key)' argument")
        }
        return value
    }

    private func parseBoolArgument(_ json: String, key: String, defaultValue: Bool) -> Bool {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = args[key] as? Bool else {
            return defaultValue
        }
        return value
    }

    private func parseIntArgument(_ json: String, key: String, defaultValue: Int) -> Int {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = args[key] as? Int else {
            return defaultValue
        }
        return value
    }
}

// MARK: - UIDocumentPickerDelegate

extension WorkspaceManager: UIDocumentPickerDelegate {
    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        if !didStart { return }

        Task { @MainActor in
            do {
                try saveBookmark(for: url)
                updateWorkspaceState(for: url)
            } catch {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    nonisolated func documentPickerWasDismissed(_ controller: UIDocumentPickerViewController) {
    }
}

// MARK: - Plugin Errors

enum FileSystemPluginError: LocalizedError {
    case invalidArguments(String)
    case accessDenied
    case fileNotFound(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): "Invalid arguments: \(msg)"
        case .accessDenied: "Access denied to the requested path"
        case .fileNotFound(let path): "File not found: \(path)"
        case .operationFailed(let msg): "Operation failed: \(msg)"
        }
    }
}
