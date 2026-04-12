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
                description: "List files and folders in a directory. Returns the contents with file names, sizes, and modification dates.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The directory path to list. Use \".\" for the root workspace directory.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "read_file",
                description: "Read the contents of a text file. Returns the file contents as a string.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The full path to the file to read.",
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
                description: "Create a new empty file at the specified path.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The full path for the new file.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "delete_file",
                description: "Delete a file at the specified path.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "path": [
                            "type": "string",
                            "description": "The full path to the file to delete.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["path"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "move_file",
                description: "Move or rename a file from source to destination.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "source": [
                            "type": "string",
                            "description": "The current path of the file.",
                        ] as [String: Any],
                        "destination": [
                            "type": "string",
                            "description": "The new path for the file.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["source", "destination"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "grep_files",
                description: "Search file contents for a pattern across the workspace. Returns matching file paths, line numbers, and matching lines.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "pattern": [
                            "type": "string",
                            "description": "The text or regex pattern to search for.",
                        ] as [String: Any],
                        "path": [
                            "type": "string",
                            "description": "The directory path to search in. Use \".\" for the workspace root.",
                        ] as [String: Any],
                        "include": [
                            "type": "string",
                            "description": "Glob pattern to filter files (e.g. \"*.swift\", \"*.{ts,tsx}\"). Default: all files.",
                        ] as [String: Any],
                        "case_insensitive": [
                            "type": "boolean",
                            "description": "Perform case-insensitive search. Default: false.",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["pattern"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "switch_mode",
                description: "Switch between chat and coding mode. Use 'coding' mode when you need to read, write, or modify code files. Use 'chat' mode for general conversation.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "mode": [
                            "type": "string",
                            "description": "The mode to switch to: 'chat' for general conversation, 'coding' for file operations.",
                            "enum": ["chat", "coding"],
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["mode"]),
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

    private func validateFileTarget(_ url: URL, path: String, allowExisting: Bool) -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return "Path is a directory, not a file: \(path)"
            }
            if !allowExisting {
                return "File already exists: \(path)"
            }
        } else {
            let parentURL = url.deletingLastPathComponent()
            guard fm.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "Parent directory does not exist: \(parentURL.lastPathComponent.isEmpty ? parentURL.path : parentURL.lastPathComponent)"
            }
        }

        return nil
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
        do {
            path = try parseArgument(argumentsJSON, key: "path", defaultValue: ".")
        } catch {
            return ToolResult(text: "Error parsing arguments: \(error.localizedDescription)")
        }

        guard let targetURL = resolvePath(path) else {
            return ToolResult(text: "Invalid path: \(path)")
        }

        do {
            let contents = try coordinatedRead(at: targetURL) { coordinatedURL in
                try FileManager.default.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            }

            var lines: [String] = []
            for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = resourceValues.isDirectory ?? false
                let size = resourceValues.fileSize ?? 0
                let date = resourceValues.contentModificationDate ?? Date.distantPast
                let dateStr = ISO8601DateFormatter().string(from: date)

                if isDir {
                    lines.append("\(dateStr)  DIR  \(fileURL.lastPathComponent)/")
                } else {
                    lines.append("\(dateStr)  \(size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : "0 B")  \(fileURL.lastPathComponent)")
                }
            }

            if lines.isEmpty {
                return ToolResult(text: "(empty directory)")
            }

            return ToolResult(text: "Contents of \(path):\n" + lines.joined(separator: "\n"))
        } catch {
            return ToolResult(text: "Error listing directory: \(error.localizedDescription)")
        }
    }

    func readFile(argumentsJSON: String) -> ToolResult {
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

        do {
            let content = try coordinatedRead(at: targetURL) { coordinatedURL in
                try String(contentsOf: coordinatedURL, encoding: .utf8)
            }
            return ToolResult(text: content)
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

        if let validationError = validateFileTarget(targetURL, path: path, allowExisting: true) {
            return ToolResult(text: validationError)
        }

        do {
            try coordinatedWrite {
                guard let data = content.data(using: .utf8) else {
                    throw FileSystemPluginError.operationFailed("Content is not valid UTF-8")
                }
                try data.write(to: targetURL, options: .atomic)
            }
            return ToolResult(text: "Successfully wrote to \(path)")
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

        let matchCount = original.components(separatedBy: oldText).count - 1
        guard matchCount > 0 else {
            return ToolResult(text: "Edit failed: old_text not found in \(path)")
        }

        if !replaceAll && matchCount != 1 {
            return ToolResult(text: "Edit failed: old_text matched \(matchCount) times in \(path). Use replace_all to replace every match.")
        }

        let updated = replaceAll
            ? original.replacingOccurrences(of: oldText, with: newText)
            : original.replacingOccurrences(of: oldText, with: newText, options: [], range: original.range(of: oldText))

        guard let updatedData = updated.data(using: .utf8) else {
            return ToolResult(text: "Error editing file: updated content is not valid UTF-8")
        }

        do {
            try coordinatedWrite {
                try updatedData.write(to: targetURL, options: .atomic)
            }
            return ToolResult(text: "Successfully edited \(path)")
        } catch {
            return ToolResult(text: "Error editing file: \(error.localizedDescription)")
        }
    }

    func createFile(argumentsJSON: String) -> ToolResult {
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

        if let validationError = validateFileTarget(targetURL, path: path, allowExisting: false) {
            return ToolResult(text: validationError)
        }

        do {
            try coordinatedWrite {
                let created = FileManager.default.createFile(atPath: targetURL.path, contents: Data())
                guard created else {
                    throw FileSystemPluginError.operationFailed("FileManager could not create the file")
                }
            }
            return ToolResult(text: "Successfully created \(path)")
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

        do {
            try coordinatedWrite {
                try FileManager.default.removeItem(at: targetURL)
            }
            return ToolResult(text: "Successfully deleted \(path)")
        } catch {
            return ToolResult(text: "Error deleting file: \(error.localizedDescription)")
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

        guard let destURL = resolvePath(destination) else {
            return ToolResult(text: "Invalid destination path: \(destination)")
        }

        if let validationError = validateFileTarget(destURL, path: destination, allowExisting: false) {
            return ToolResult(text: validationError)
        }

        do {
            try coordinatedWrite {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            }
            return ToolResult(text: "Successfully moved \(source) to \(destination)")
        } catch {
            return ToolResult(text: "Error moving file: \(error.localizedDescription)")
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
        do {
            pattern = try parseArgument(argumentsJSON, key: "pattern")
            path = try parseArgument(argumentsJSON, key: "path", defaultValue: ".")
            include = try? parseArgument(argumentsJSON, key: "include", defaultValue: nil)
            caseInsensitive = parseBoolArgument(argumentsJSON, key: "case_insensitive", defaultValue: false)
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

        let extensions = parseIncludeGlob(include)
        var results: [String] = []
        let maxResults = 50

        func searchDirectory(_ dirURL: URL) {
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let fileURL as URL in enumerator {
                guard results.count < maxResults else { break }

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                      !isDir.boolValue else { continue }

                if !extensions.isEmpty {
                    let ext = fileURL.pathExtension.lowercased()
                    if !extensions.contains(ext) {
                        continue
                    }
                }

                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

                let nsContent = content as NSString
                let fullRange = NSRange(location: 0, length: nsContent.length)
                let matches = regex.matches(in: content as String, options: [], range: fullRange)

                guard !matches.isEmpty else { continue }

                let relativePath: String
                if let root = _currentURL {
                    relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
                } else {
                    relativePath = fileURL.lastPathComponent
                }

                for match in matches.prefix(10) {
                    let lineRange = nsContent.lineRange(for: match.range)
                    let lineNumber = nsContent.substring(with: NSRange(location: 0, length: lineRange.lowerBound))
                        .components(separatedBy: .newlines).count
                    let lineText = nsContent.substring(with: lineRange).trimmingCharacters(in: .newlines)
                    results.append("\(relativePath):\(lineNumber): \(lineText)")
                }
            }
        }

        try? coordinatedRead(at: searchURL) { coordinatedURL in
            searchDirectory(coordinatedURL)
        }

        if results.isEmpty {
            return ToolResult(text: "No matches found for pattern: \(pattern)")
        }

        let truncated = results.count >= maxResults ? "\n\n(Results truncated at \(maxResults) matches)" : ""
        return ToolResult(text: results.joined(separator: "\n") + truncated)
    }

    private func parseIncludeGlob(_ glob: String?) -> [String] {
        guard let glob, !glob.isEmpty else { return [] }
        if glob.hasPrefix("*.") {
            let ext = String(glob.dropFirst(2)).lowercased()
            if ext.hasPrefix("{") && ext.hasSuffix("}") {
                let inner = String(ext.dropFirst().dropLast())
                return inner.split(separator: ",").map(String.init)
            }
            return [ext]
        }
        return []
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
