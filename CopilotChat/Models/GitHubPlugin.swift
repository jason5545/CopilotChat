import Foundation
import SwiftGit2
import Clibgit2

@MainActor
final class GitHubPlugin: Plugin {
    let id = "com.copilotchat.github"
    let name = "GitHub"
    let version = "1.0.0"

    private var cachedToken: String? {
        KeychainHelper.loadString(key: AuthManager.keychainKey)
    }

    func configure(with input: PluginInput) async throws -> PluginHooks {
        let tools = [
            MCPTool(name: "github_clone", description: "Clone a GitHub repository into the current workspace directory.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["repo_url": ["type": "string", "description": "GitHub repository URL (e.g. 'https://github.com/owner/repo.git')"] as [String: Any]]),
                "required": AnyCodable(["repo_url"]),
            ], serverName: name),
            MCPTool(name: "github_push", description: "Stage all changes, commit, and push to the remote repository.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "message": ["type": "string", "description": "Commit message"] as [String: Any],
                    "branch": ["type": "string", "description": "Branch to push to (defaults to current)"] as [String: Any],
                ]),
                "required": AnyCodable(["message"]),
            ], serverName: name),
            MCPTool(name: "github_pull", description: "Pull latest changes from the remote repository.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_fetch", description: "Fetch latest objects from the remote without merging.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_status", description: "Show git status — modified, untracked, staged, and deleted files.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_log", description: "Show recent commit history.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["count": ["type": "integer", "description": "Number of commits (default: 10)"] as [String: Any]]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_diff", description: "Show changes in the working directory compared to the last commit.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_branch_list", description: "List all local and remote branches.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_branch_checkout", description: "Switch to an existing branch.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["branch": ["type": "string", "description": "Branch name to switch to"] as [String: Any]]),
                "required": AnyCodable(["branch"]),
            ], serverName: name),
            MCPTool(name: "github_branch_create", description: "Create a new branch and switch to it.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["branch": ["type": "string", "description": "New branch name"] as [String: Any]]),
                "required": AnyCodable(["branch"]),
            ], serverName: name),
            MCPTool(name: "github_remote_list", description: "List all remote repositories.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_tag_list", description: "List all tags in the repository.", inputSchema: [
                "type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any]), "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_list_repos", description: "List your GitHub repositories (via GitHub API).", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "count": ["type": "integer", "description": "Max repos to list (default: 20)"] as [String: Any],
                    "sort": ["type": "string", "description": "Sort by: pushed, created, updated, full_name (default: pushed)"] as [String: Any],
                ]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_create_repo", description: "Create a new GitHub repository and optionally push current workspace as initial commit.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "name": ["type": "string", "description": "Repository name"] as [String: Any],
                    "private": ["type": "boolean", "description": "Private repo (default: true)"] as [String: Any],
                    "description": ["type": "string", "description": "Short description"] as [String: Any],
                    "push_initial": ["type": "boolean", "description": "Push workspace as initial commit (default: true)"] as [String: Any],
                ]),
                "required": AnyCodable(["name"]),
            ], serverName: name),
        ]

        return PluginHooks(tools: tools) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        guard let token = cachedToken else {
            return ToolResult(text: "Not authenticated. Please sign in with GitHub in Settings.")
        }
        switch name {
        case "github_clone": return try await clone(argumentsJSON: argumentsJSON, token: token)
        case "github_push": return try await push(argumentsJSON: argumentsJSON, token: token)
        case "github_pull": return try await pull(token: token)
        case "github_fetch": return try await fetch(token: token)
        case "github_status": return try await status()
        case "github_log": return try await log(argumentsJSON: argumentsJSON)
        case "github_diff": return try await diff()
        case "github_branch_list": return try await branchList()
        case "github_branch_checkout": return try await branchCheckout(argumentsJSON: argumentsJSON)
        case "github_branch_create": return try await branchCreate(argumentsJSON: argumentsJSON)
        case "github_remote_list": return try await remoteList()
        case "github_tag_list": return try await tagList()
        case "github_list_repos": return try await listRepos(argumentsJSON: argumentsJSON, token: token)
        case "github_create_repo": return try await createRepo(argumentsJSON: argumentsJSON, token: token)
        default: throw PluginRegistry.PluginError.unknownTool(name)
        }
    }

    // MARK: - Helpers

    private func parseArg(_ json: String, key: String, default: String? = nil) throws -> String {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = args[key] as? String else {
            if let `default` { return `default` }
            throw PluginError.invalidArguments("Missing '\(key)'")
        }
        return value
    }

    private func boolArg(_ json: String, key: String, default: Bool) -> Bool {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = args[key] as? Bool else { return `default` }
        return v
    }

    private func intArg(_ json: String, key: String, default: Int) -> Int {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = args[key] as? Int else { return `default` }
        return v
    }

    private func findGitRepoURL() -> URL? {
        guard let wsURL = WorkspaceManager.shared.currentURL else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: wsURL.appendingPathComponent(".git").path, isDirectory: &isDir), isDir.boolValue {
            return wsURL
        }
        if let contents = try? FileManager.default.contentsOfDirectory(at: wsURL, includingPropertiesForKeys: nil),
           contents.count == 1 {
            let child = contents[0]
            var cDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path, isDirectory: &cDir), cDir.boolValue {
                return child
            }
        }
        return nil
    }

    private func withRepo(_ body: @Sendable @escaping (Repository) -> ToolResult) async -> ToolResult {
        guard let repoURL = findGitRepoURL() else {
            return ToolResult(text: "Current workspace is not a git repository.")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch Repository.at(repoURL) {
                case .success(let repo): continuation.resume(returning: body(repo))
                case .failure(let e): continuation.resume(returning: ToolResult(text: "Failed to open repo: \(e.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - Clone

    private func clone(argumentsJSON: String, token: String) async throws -> ToolResult {
        let repoURLString = try parseArg(argumentsJSON, key: "repo_url")
        guard let wsURL = WorkspaceManager.shared.currentURL else {
            return ToolResult(text: "No workspace selected.")
        }
        guard let remoteURL = URL(string: repoURLString) else {
            return ToolResult(text: "Invalid URL: \(repoURLString)")
        }
        let repoName = remoteURL.lastPathComponent.replacingOccurrences(of: ".git", with: "")
        let dest = wsURL.appendingPathComponent(repoName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            return ToolResult(text: "Directory already exists: \(repoName)/")
        }
        return await withCheckedContinuation { continuation in
            let creds = Credentials.plaintext(username: "x-access-token", password: token)
            DispatchQueue.global(qos: .userInitiated).async {
                switch Repository.clone(from: remoteURL, to: dest, credentials: creds, checkoutStrategy: .Force) {
                case .success: continuation.resume(returning: ToolResult(text: "Cloned into \(repoName)/"))
                case .failure(let e): continuation.resume(returning: ToolResult(text: "Clone failed: \(e.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - Push

    private func push(argumentsJSON: String, token: String) async throws -> ToolResult {
        let message = try parseArg(argumentsJSON, key: "message")
        let branch: String? = try? parseArg(argumentsJSON, key: "branch")
        guard let repoURL = findGitRepoURL() else {
            return ToolResult(text: "Not a git repository. Clone or create one first.")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch Repository.at(repoURL) {
                case .failure(let e):
                    continuation.resume(returning: ToolResult(text: "Open failed: \(e.localizedDescription)"))
                case .success(let repo):
                    let _ = repo.add(path: ".")
                    let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
                    switch repo.commit(message: message, signature: sig) {
                    case .failure(let e):
                        continuation.resume(returning: ToolResult(text: "Commit failed: \(e.localizedDescription)"))
                    case .success(let commit):
                        repo.push(repo, "x-access-token", token, branch.map { "refs/heads/\($0)" })
                        let short = String(commit.oid.description.prefix(7))
                        continuation.resume(returning: ToolResult(text: "Pushed \(short): \(message)"))
                    }
                }
            }
        }
    }

    // MARK: - Pull

    private func pull(token: String) async throws -> ToolResult {
        await withRepo { repo in
            switch repo.remote(named: "origin") {
            case .failure(let e): return ToolResult(text: "No remote 'origin': \(e.localizedDescription)")
            case .success(let remote):
                switch repo.fetch(remote) {
                case .failure(let e): return ToolResult(text: "Fetch failed: \(e.localizedDescription)")
                case .success:
                    switch repo.checkout(strategy: .Force) {
                    case .failure(let e): return ToolResult(text: "Checkout failed: \(e.localizedDescription)")
                    case .success: return ToolResult(text: "Pulled latest changes.")
                    }
                }
            }
        }
    }

    // MARK: - Fetch

    private func fetch(token: String) async throws -> ToolResult {
        await withRepo { repo in
            switch repo.remote(named: "origin") {
            case .failure(let e): return ToolResult(text: "No remote 'origin': \(e.localizedDescription)")
            case .success(let remote):
                switch repo.fetch(remote) {
                case .failure(let e): return ToolResult(text: "Fetch failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "Fetched latest objects from origin.")
                }
            }
        }
    }

    // MARK: - Status

    private func status() async throws -> ToolResult {
        await withRepo { repo in
            switch repo.status() {
            case .failure(let e): return ToolResult(text: "Status failed: \(e.localizedDescription)")
            case .success(let entries):
                if entries.isEmpty { return ToolResult(text: "Working tree clean.") }
                var staged: [String] = [], modified: [String] = [], untracked: [String] = [], deleted: [String] = []
                for entry in entries {
                    let path = entry.headToIndex?.newFile?.path
                        ?? entry.indexToWorkDir?.oldFile?.path
                        ?? entry.indexToWorkDir?.newFile?.path ?? "?"
                    let s = entry.status
                    if s.contains(.workTreeNew) { untracked.append(path) }
                    else if s.contains(.workTreeModified) { modified.append(path) }
                    else if s.contains(.workTreeDeleted) { deleted.append(path) }
                    else if s.contains(.indexNew) || s.contains(.indexModified) { staged.append(path) }
                }
                var lines: [String] = []
                if !staged.isEmpty { lines.append("Staged:"); lines.append(contentsOf: staged.map { "  + \($0)" }) }
                if !modified.isEmpty { lines.append("Modified:"); lines.append(contentsOf: modified.map { "  M \($0)" }) }
                if !deleted.isEmpty { lines.append("Deleted:"); lines.append(contentsOf: deleted.map { "  D \($0)" }) }
                if !untracked.isEmpty { lines.append("Untracked:"); lines.append(contentsOf: untracked.map { "  ? \($0)" }) }
                return ToolResult(text: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Log

    private func log(argumentsJSON: String) async throws -> ToolResult {
        let count = intArg(argumentsJSON, key: "count", default: 10)
        return await withRepo { repo in
            switch repo.HEAD() {
            case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
            case .success(let ref):
                guard let branch = ref as? Branch else { return ToolResult(text: "HEAD is detached.") }
                var lines: [String] = []
                var n = 0
                for r in repo.commits(in: branch) {
                    if n >= count { break }
                    guard let c = try? r.get() else { continue }
                    let oid = String(c.oid.description.prefix(7))
                    let date = ISO8601DateFormatter().string(from: c.author.time)
                    let msg = c.message.split(separator: "\n").first ?? ""
                    lines.append("\(oid) \(c.author.name) \(date)\n  \(msg)")
                    n += 1
                }
                return ToolResult(text: lines.isEmpty ? "No commits." : lines.joined(separator: "\n\n"))
            }
        }
    }

    // MARK: - Diff

    private func diff() async throws -> ToolResult {
        await withRepo { repo in
            switch repo.HEAD() {
            case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
            case .success(let ref):
                switch repo.diff(for: ref as! Commit) {
                case .failure(let e): return ToolResult(text: "Diff failed: \(e.localizedDescription)")
                case .success(let diff):
                    if diff.deltas.isEmpty { return ToolResult(text: "No changes in last commit.") }
                    var lines: [String] = []
                    for delta in diff.deltas {
                        let status: String
                        switch delta.status.rawValue {
                        case 65: status = "A"
                        case 68: status = "D"
                        case 77: status = "M"
                        case 82: status = "R"
                        case 84: status = "T"
                        default: status = "?"
                        }
                        let old = delta.oldFile?.path ?? "?"
                        let new = delta.newFile?.path ?? "?"
                        if old == new { lines.append("  \(status) \(old)") }
                        else { lines.append("  \(status) \(old) → \(new)") }
                    }
                    return ToolResult(text: lines.joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: - Branch List

    private func branchList() async throws -> ToolResult {
        await withRepo { repo in
            var lines: [String] = []
            let headName = (try? repo.HEAD().get()).flatMap { ($0 as? Branch)?.name }
            switch repo.localBranches() {
            case .success(let branches):
                for b in branches {
                    let marker = b.name == headName ? "* " : "  "
                    lines.append("\(marker)\(b.name)")
                }
            case .failure: break
            }
            switch repo.remoteBranches() {
            case .success(let branches):
                if !branches.isEmpty {
                    if !lines.isEmpty { lines.append("") }
                    lines.append("Remotes:")
                    for b in branches { lines.append("  \(b.name)") }
                }
            case .failure: break
            }
            return ToolResult(text: lines.isEmpty ? "No branches." : lines.joined(separator: "\n"))
        }
    }

    // MARK: - Branch Checkout

    private func branchCheckout(argumentsJSON: String) async throws -> ToolResult {
        let branch = try parseArg(argumentsJSON, key: "branch")
        return await withRepo { repo in
            switch repo.localBranch(named: branch) {
            case .failure(let e): return ToolResult(text: "Branch '\(branch)' not found: \(e.localizedDescription)")
            case .success(let b):
                switch repo.checkout(b, strategy: .Force) {
                case .failure(let e): return ToolResult(text: "Checkout failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "Switched to branch '\(branch)'.")
                }
            }
        }
    }

    // MARK: - Branch Create

    private func branchCreate(argumentsJSON: String) async throws -> ToolResult {
        let branch = try parseArg(argumentsJSON, key: "branch")
        return await withRepo { repo in
            switch repo.checkoutOrCreateBranch(named: branch, checkoutStrategy: .Force) {
            case .success: return ToolResult(text: "Created and switched to branch '\(branch)'.")
            case .failure(let e): return ToolResult(text: "Create branch failed: \(e.localizedDescription)")
            }
        }
    }

    // MARK: - Remote List

    private func remoteList() async throws -> ToolResult {
        await withRepo { repo in
            switch repo.allRemotes() {
            case .failure(let e): return ToolResult(text: "Failed: \(e.localizedDescription)")
            case .success(let remotes):
                if remotes.isEmpty { return ToolResult(text: "No remotes configured.") }
                return ToolResult(text: remotes.map { "\($0.name)\t\($0.URL)" }.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Tag List

    private func tagList() async throws -> ToolResult {
        await withRepo { repo in
            switch repo.allTags() {
            case .failure(let e): return ToolResult(text: "Failed: \(e.localizedDescription)")
            case .success(let tags):
                if tags.isEmpty { return ToolResult(text: "No tags.") }
                return ToolResult(text: tags.map { $0.name }.joined(separator: "\n"))
            }
        }
    }

    // MARK: - List Repos (GitHub API)

    private func listRepos(argumentsJSON: String, token: String) async throws -> ToolResult {
        let perPage = intArg(argumentsJSON, key: "count", default: 20)
        let sort = try? parseArg(argumentsJSON, key: "sort", default: "pushed")

        var url = URLComponents(string: "https://api.github.com/user/repos")!
        url.queryItems = [
            URLQueryItem(name: "per_page", value: "\(min(perPage, 100))"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: "desc"),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AuthManager.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return ToolResult(text: "GitHub API error.")
        }
        guard let repos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ToolResult(text: "Failed to parse response.")
        }
        if repos.isEmpty { return ToolResult(text: "No repositories found.") }
        let lines = repos.compactMap { repo -> String? in
            guard let name = repo["full_name"] as? String else { return nil }
            let priv = repo["private"] as? Bool == true ? "🔒" : "🌐"
            let desc = repo["description"] as? String ?? ""
            return "\(priv) \(name)\(desc.isEmpty ? "" : " — \(desc)")"
        }
        return ToolResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - Create Repo (GitHub API)

    private func createRepo(argumentsJSON: String, token: String) async throws -> ToolResult {
        let name = try parseArg(argumentsJSON, key: "name")
        let isPrivate = boolArg(argumentsJSON, key: "private", default: true)
        let desc = try? parseArg(argumentsJSON, key: "description", default: "")
        let pushInitial = boolArg(argumentsJSON, key: "push_initial", default: true)

        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos")!)
        request.httpMethod = "POST"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AuthManager.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": false]
        if let desc, !desc.isEmpty { body["description"] = desc }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            return ToolResult(text: "GitHub API error (\(code)): \(body)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let htmlURL = json["html_url"] as? String,
              let cloneURL = json["clone_url"] as? String,
              let fullName = json["full_name"] as? String else {
            return ToolResult(text: "Created but failed to parse response.")
        }
        if !pushInitial {
            return ToolResult(text: "Repository created: \(htmlURL)\nClone URL: \(cloneURL)")
        }
        guard let wsURL = WorkspaceManager.shared.currentURL else {
            return ToolResult(text: "Repository created: \(htmlURL)\nNo workspace to push.")
        }

        let initOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: Repository.create(at: wsURL).isSuccess) }
        }
        guard initOK else { return ToolResult(text: "Repository created: \(htmlURL)\nGit init failed.") }

        let remoteStr = "https://x-access-token:\(token)@github.com/\(fullName).git"
        let remoteOK = await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Repository.at(wsURL)
                switch r {
                case .success(let repo):
                    var ptr: OpaquePointer?
                    let res = remoteStr.withCString { git_remote_create(&ptr, repo.pointer, "origin", $0) }
                    if res == GIT_OK.rawValue { git_remote_free(ptr) }
                    c.resume(returning: res)
                case .failure: c.resume(returning: Int32(-1))
                }
            }
        }
        guard remoteOK == GIT_OK.rawValue else {
            return ToolResult(text: "Repository created: \(htmlURL)\nFailed to add remote.")
        }

        let pushJSON = try JSONSerialization.data(withJSONObject: ["message": "Initial commit"])
        let pushResult = try await push(argumentsJSON: String(data: pushJSON, encoding: .utf8)!, token: token)
        return ToolResult(text: "Created and pushed: \(htmlURL)\n\(pushResult.text)")
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
