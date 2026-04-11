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

    private var _currentURL: URL?
    private var _workspaceName: String?
    private var _isAccessing: Bool = false

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
                _currentURL = url
                _workspaceName = url.lastPathComponent
                _isAccessing = true
                _trackedHasWorkspace = true
                _trackedWorkspaceName = url.lastPathComponent
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
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
            let contents = try FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

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
            let content = try String(contentsOf: targetURL, encoding: .utf8)
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
            guard let data = content.data(using: .utf8) else {
                return ToolResult(text: "Error writing file: content is not valid UTF-8")
            }
            try data.write(to: targetURL, options: .atomic)
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

        guard let originalData = try? Data(contentsOf: targetURL),
              let original = String(data: originalData, encoding: .utf8) else {
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
            try updatedData.write(to: targetURL, options: .atomic)
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
            let created = FileManager.default.createFile(atPath: targetURL.path, contents: Data())
            guard created else {
                return ToolResult(text: "Error creating file: FileManager could not create the file")
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
            try FileManager.default.removeItem(at: targetURL)
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
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            return ToolResult(text: "Successfully moved \(source) to \(destination)")
        } catch {
            return ToolResult(text: "Error moving file: \(error.localizedDescription)")
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
                _currentURL = url
                _workspaceName = url.lastPathComponent
                _isAccessing = true
                _trackedHasWorkspace = true
                _trackedWorkspaceName = url.lastPathComponent
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
