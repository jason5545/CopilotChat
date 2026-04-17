import Foundation
import SwiftUI

struct FileMention: Identifiable, Hashable {
    let id = UUID()
    let relativePath: String
    let fileName: String
    let fileExtension: String
    let isDirectory: Bool

    var displayName: String {
        fileName
    }

    var fullPath: String {
        relativePath
    }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        return FileMention.iconForExtension(fileExtension)
    }

    var tintColor: Color {
        FileMention.colorForExtension(fileExtension)
    }

    static func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "rs": return "gearshape"
        case "go": return "terminal"
        case "java", "kt": return "cup.and.saucer"
        case "rb": return "diamond"
        case "c", "cpp", "h", "hpp": return "microchip"
        case "html": return "globe"
        case "css", "scss", "less": return "paintbrush"
        case "json", "yaml", "yml", "toml", "xml", "plist": return "doc.text"
        case "md", "txt", "rtf": return "doc.plaintext"
        case "sh", "bash", "zsh": return "terminal"
        case "sql": return "cylinder"
        case "dockerfile": return "shippingbox"
        case "lock": return "lock"
        case "png", "jpg", "jpeg", "gif", "svg", "ico", "webp": return "photo"
        default: return "doc"
        }
    }

    static func colorForExtension(_ ext: String) -> Color {
        switch ext.lowercased() {
        case "swift": return .orange
        case "js", "jsx": return .yellow
        case "ts", "tsx": return .blue
        case "py": return .cyan
        case "rs": return .orange
        case "go": return .cyan
        case "java", "kt": return .purple
        case "rb": return .red
        case "c", "cpp", "h", "hpp": return .blue
        case "html": return .orange
        case "css", "scss": return .purple
        case "json", "yaml", "yml", "toml": return .green
        case "md", "txt": return Color.carbonTextSecondary
        case "sh", "bash": return .green
        default: return Color.carbonTextTertiary
        }
    }
}

@MainActor
final class FileMentionManager: ObservableObject {
    @Published var allFiles: [FileMention] = []
    @Published var filteredFiles: [FileMention] = []
    @Published var isIndexing = false

    private var indexedWorkspaceIdentifier: String?
    private var currentQuery = ""

    private let maxResults = 30
    private let ignoredExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "ico", "webp", "svg", "mp4", "mov",
        "mp3", "wav", "aiff", "flac", "zip", "gz", "tar", "rar", "7z",
        "dSYM", "o", "pyc", "class", "exe", "dll", "so", "dylib",
        "framework", "bundle", "xcassets", "nib", "xib", "storyboardc",
        "pbxproj", "xcworkspacedata", "xcuserstate",
    ]
    private let ignoredDirectories: Set<String> = [
        ".git", ".svn", "node_modules", "__pycache__", ".build",
        "DerivedData", "build", ".gradle", ".idea", ".vscode",
        "Pods", ".tuist-bundle", ".swiftpm",
    ]

    func indexWorkspace() {
        refreshWorkspaceIndexIfNeeded(force: true)
    }

    func refreshWorkspaceIndexIfNeeded(force: Bool = false) {
        guard let workspaceURL = WorkspaceManager.shared.currentURL else {
            indexedWorkspaceIdentifier = nil
            allFiles = []
            filteredFiles = []
            isIndexing = false
            return
        }

        let workspaceIdentifier = workspaceURL.absoluteString
        guard force || indexedWorkspaceIdentifier != workspaceIdentifier || allFiles.isEmpty else { return }

        indexedWorkspaceIdentifier = workspaceIdentifier
        allFiles = []
        filteredFiles = []
        isIndexing = true
        let ignoredDirectories = ignoredDirectories
        let ignoredExtensions = ignoredExtensions

        Task.detached(priority: .utility) {
            let files = Self.scanDirectory(
                workspaceURL,
                rootURL: workspaceURL,
                ignoredDirs: ignoredDirectories,
                ignoredExts: ignoredExtensions
            )

            await MainActor.run {
                guard self.indexedWorkspaceIdentifier == workspaceIdentifier else { return }
                self.allFiles = files
                self.isIndexing = false
                self.applySearch(query: self.currentQuery)
            }
        }
    }

    func search(query: String) {
        currentQuery = query
        refreshWorkspaceIndexIfNeeded()
        applySearch(query: query)
    }

    private func applySearch(query: String) {
        guard !query.isEmpty else {
            filteredFiles = Array(allFiles.prefix(maxResults))
            return
        }

        let lower = query.lowercased()
        filteredFiles = allFiles.filter { file in
            file.fileName.lowercased().contains(lower) ||
            file.relativePath.lowercased().contains(lower)
        }
        filteredFiles.sort { a, b in
            let aStarts = a.fileName.lowercased().hasPrefix(lower)
            let bStarts = b.fileName.lowercased().hasPrefix(lower)
            if aStarts != bStarts { return aStarts }
            let aContains = a.fileName.lowercased().contains(lower)
            let bContains = b.fileName.lowercased().contains(lower)
            if aContains != bContains { return aContains }
            return a.relativePath < b.relativePath
        }
        if filteredFiles.count > maxResults {
            filteredFiles = Array(filteredFiles.prefix(maxResults))
        }
    }

    func readFileContent(_ mention: FileMention) -> String? {
        guard let workspaceURL = WorkspaceManager.shared.currentURL else { return nil }
        let fileURL = workspaceURL.appendingPathComponent(mention.relativePath)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private nonisolated static func scanDirectory(_ url: URL, rootURL: URL, ignoredDirs: Set<String>, ignoredExts: Set<String>, depth: Int = 0) -> [FileMention] {
        guard depth < 12 else { return [] }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .nameKey], options: [.skipsHiddenFiles]) else { return [] }

        var results: [FileMention] = []
        var count = 0
        let maxFiles = 5000

        for case let itemURL as URL in enumerator {
            guard count < maxFiles else { break }
            count += 1

            let name = itemURL.lastPathComponent
            let ext = itemURL.pathExtension

            if let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
               resourceValues.isDirectory == true {
                if ignoredDirs.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }

            if ignoredExts.contains(ext.lowercased()) {
                continue
            }

            guard let relative = itemURL.path.relativePath(from: rootURL) else { continue }

            results.append(FileMention(
                relativePath: relative,
                fileName: name,
                fileExtension: ext,
                isDirectory: false
            ))
        }

        return results.sorted { $0.relativePath < $1.relativePath }
    }
}

extension String {
    func relativePath(from baseURL: URL) -> String? {
        let base = baseURL.path
        guard self.hasPrefix(base) else { return nil }
        let relative = String(self.dropFirst(base.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }
}
