import Foundation
import Clibgit2

@MainActor
final class GitHubPlugin: Plugin {
    let id = "com.copilotchat.github"
    let name = "GitHub"
    let version = "1.0.0"

    nonisolated private static let allowedGitHubHosts: Set<String> = ["github.com", "www.github.com"]

    private struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var _cachedToken: String?
    private var _cachedTokenDate: Date?

    private var cachedToken: String? {
        if let cached = _cachedToken, let date = _cachedTokenDate,
           Date().timeIntervalSince(date) < 300 { return cached }
        let token = KeychainHelper.loadString(key: AuthManager.keychainKey)
        _cachedToken = token
        _cachedTokenDate = Date()
        return token
    }

    private static let repoPathParam: [String: Any] = ["type": "string", "description": "Subdirectory path within the workspace (for parent folder workspaces with multiple repos)"]

    func configure(with input: PluginInput) async throws -> PluginHooks {
        let tools = [
            MCPTool(name: "github_clone", description: "Clone a GitHub repository into the current workspace directory. Uses shallow clone (depth 1) by default for speed.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "repo_url": ["type": "string", "description": "GitHub repository URL (e.g. 'https://github.com/owner/repo.git')"] as [String: Any],
                    "depth": ["type": "integer", "description": "Clone depth (default: 1 for shallow clone, 0 for full history)"] as [String: Any],
                ]),
                "required": AnyCodable(["repo_url"]),
            ], serverName: name),
            MCPTool(name: "github_push", description: "Stage all changes, commit, and push to the remote repository.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "message": ["type": "string", "description": "Commit message"] as [String: Any],
                    "branch": ["type": "string", "description": "Branch to push to (defaults to current)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["message"]),
            ], serverName: name),
            MCPTool(name: "github_pull", description: "Pull latest changes from the remote repository.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_fetch", description: "Fetch latest objects from the remote without merging.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_status", description: "Show git status — modified, untracked, staged, and deleted files.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_log", description: "Show recent commit history.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["count": ["type": "integer", "description": "Number of commits (default: 10)"] as [String: Any], "path": Self.repoPathParam]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_diff", description: "Show changes in the working directory compared to the last commit.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_branch_list", description: "List all local and remote branches.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_branch_checkout", description: "Switch to an existing branch.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["branch": ["type": "string", "description": "Branch name to switch to"] as [String: Any], "path": Self.repoPathParam]),
                "required": AnyCodable(["branch"]),
            ], serverName: name),
            MCPTool(name: "github_branch_create", description: "Create a new branch and switch to it.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["branch": ["type": "string", "description": "New branch name"] as [String: Any], "path": Self.repoPathParam]),
                "required": AnyCodable(["branch"]),
            ], serverName: name),
            MCPTool(name: "github_remote_list", description: "List all remote repositories.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_tag_list", description: "List all tags in the repository.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": Self.repoPathParam] as [String: Any]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_reset", description: "Reset current HEAD to a specified commit, branch, or tag. Supports --soft (move HEAD only), --mixed (default, reset staging area), --hard (discard all changes), and pathspec-based reset (unstage specific files).", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "target": ["type": "string", "description": "Commit hash, branch name, tag, or revision (e.g. 'HEAD~1', 'abc1234'). Defaults to HEAD. For pathspec reset, omit this or set to 'HEAD'."] as [String: Any],
                    "mode": ["type": "string", "description": "Reset mode: 'soft' (move HEAD only), 'mixed' (reset index, default), 'hard' (discard working tree changes). Ignored when paths are specified."] as [String: Any],
                    "paths": ["type": "array", "items": ["type": "string"], "description": "Optional list of file paths to unstage (pathspec reset). When provided, performs a mixed reset only for these files, like 'git reset -- <paths>'."] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable([]),
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
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["name"]),
            ], serverName: name),
            MCPTool(name: "github_add", description: "Stage file(s) to the index (like 'git add'). Does not commit.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "paths": ["type": "array", "items": ["type": "string"], "description": "File paths to stage (e.g. ['file.swift', 'dir/'])"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["paths"]),
            ], serverName: name),
            MCPTool(name: "github_commit", description: "Commit staged changes without pushing (like 'git commit').", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "message": ["type": "string", "description": "Commit message"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["message"]),
            ], serverName: name),
            MCPTool(name: "github_show", description: "Show commit details: author, date, message, and file changes.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "revision": ["type": "string", "description": "Commit hash, branch, tag, or revision (e.g. 'HEAD', 'abc1234'). Defaults to HEAD."] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_stash", description: "Stash, list, apply, pop, or drop stashed changes.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "action": ["type": "string", "description": "Action: 'save' (default), 'list', 'apply', 'pop', 'drop'"] as [String: Any],
                    "message": ["type": "string", "description": "Stash message (for 'save')"] as [String: Any],
                    "index": ["type": "integer", "description": "Stash index for apply/pop/drop (default: 0)"] as [String: Any],
                    "include_untracked": ["type": "boolean", "description": "Include untracked files (default: true)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_merge", description: "Merge a branch into the current branch.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "branch": ["type": "string", "description": "Branch or revision to merge"] as [String: Any],
                    "message": ["type": "string", "description": "Merge commit message (auto-generated if omitted)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["branch"]),
            ], serverName: name),
            MCPTool(name: "github_cherry_pick", description: "Cherry-pick a commit onto the current branch.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "commit": ["type": "string", "description": "Commit hash to cherry-pick"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["commit"]),
            ], serverName: name),
            MCPTool(name: "github_revert", description: "Revert a commit by creating a new commit that undoes its changes.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "commit": ["type": "string", "description": "Commit hash to revert"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["commit"]),
            ], serverName: name),
            MCPTool(name: "github_branch_delete", description: "Delete a local branch.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "branch": ["type": "string", "description": "Branch name to delete"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["branch"]),
            ], serverName: name),
            MCPTool(name: "github_tag_create", description: "Create a tag (annotated or lightweight) at a specific commit.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "name": ["type": "string", "description": "Tag name"] as [String: Any],
                    "target": ["type": "string", "description": "Commit hash, branch, or revision to tag (default: HEAD)"] as [String: Any],
                    "message": ["type": "string", "description": "Tag message (creates annotated tag if provided, lightweight if omitted)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["name"]),
            ], serverName: name),
            MCPTool(name: "github_tag_delete", description: "Delete a tag.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "name": ["type": "string", "description": "Tag name to delete"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["name"]),
            ], serverName: name),
            MCPTool(name: "github_remote_add", description: "Add a remote repository.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "name": ["type": "string", "description": "Remote name (e.g. 'origin')"] as [String: Any],
                    "url": ["type": "string", "description": "Remote URL"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["name", "url"]),
            ], serverName: name),
            MCPTool(name: "github_remote_remove", description: "Remove a remote repository.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "name": ["type": "string", "description": "Remote name to remove"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["name"]),
            ], serverName: name),
            MCPTool(name: "github_rm", description: "Remove files from the index and working tree (like 'git rm').", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "paths": ["type": "array", "items": ["type": "string"], "description": "File paths to remove"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["paths"]),
            ], serverName: name),
            MCPTool(name: "github_blame", description: "Show line-level authorship for a file (like 'git blame').", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "file": ["type": "string", "description": "File path to blame"] as [String: Any],
                    "revision": ["type": "string", "description": "Commit to blame at (default: HEAD)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["file"]),
            ], serverName: name),
            MCPTool(name: "github_reflog", description: "Show the reference log for HEAD or a specific ref.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "ref": ["type": "string", "description": "Reference name (default: HEAD)"] as [String: Any],
                    "count": ["type": "integer", "description": "Max entries to show (default: 20)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_clean", description: "Remove untracked files from the working tree (like 'git clean').", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "directories": ["type": "boolean", "description": "Also remove untracked directories (default: false)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_describe", description: "Give a human-readable name to the current commit based on tags (like 'git describe').", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "revision": ["type": "string", "description": "Commit to describe (default: HEAD)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable([]),
            ], serverName: name),
            MCPTool(name: "github_config", description: "Get or set git configuration values.", inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "key": ["type": "string", "description": "Config key (e.g. 'user.name', 'core.autocrlf')"] as [String: Any],
                    "value": ["type": "string", "description": "Value to set (omit to get current value)"] as [String: Any],
                    "path": Self.repoPathParam,
                ]),
                "required": AnyCodable(["key"]),
            ], serverName: name),
        ]

        return PluginHooks(tools: tools) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        } onExecuteStreaming: { [weak self] toolName, argumentsJSON, progressHandler in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeToolStreaming(name: toolName, argumentsJSON: argumentsJSON, progressHandler: progressHandler)
        }
    }

    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        guard let token = cachedToken else {
            return ToolResult(text: "Not authenticated. Please sign in with GitHub in Settings.")
        }
        let subpath = (try? parseArg(argumentsJSON, key: "path", default: nil)) ?? nil
        switch name {
        case "github_clone": return try await clone(argumentsJSON: argumentsJSON, token: token)
        case "github_push": return try await push(argumentsJSON: argumentsJSON, token: token, subpath: subpath)
        case "github_pull": return try await pull(token: token, subpath: subpath)
        case "github_fetch": return try await fetch(token: token, subpath: subpath)
        case "github_status": return try await status(subpath: subpath)
        case "github_log": return try await log(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_diff": return try await diff(subpath: subpath)
        case "github_branch_list": return try await branchList(subpath: subpath)
        case "github_branch_checkout": return try await branchCheckout(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_branch_create": return try await branchCreate(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_remote_list": return try await remoteList(subpath: subpath)
        case "github_tag_list": return try await tagList(subpath: subpath)
        case "github_reset": return try await reset(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_add": return try await addFiles(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_commit": return try await commitOnly(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_show": return try await show(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_stash": return try await stash(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_merge": return try await merge(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_cherry_pick": return try await cherryPick(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_revert": return try await revert(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_branch_delete": return try await branchDelete(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_tag_create": return try await tagCreate(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_tag_delete": return try await tagDelete(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_remote_add": return try await remoteAdd(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_remote_remove": return try await remoteRemove(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_rm": return try await removeFiles(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_blame": return try await blame(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_reflog": return try await reflog(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_clean": return try await clean(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_describe": return try await describe(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_config": return try await config(argumentsJSON: argumentsJSON, subpath: subpath)
        case "github_list_repos": return try await listRepos(argumentsJSON: argumentsJSON, token: token)
        case "github_create_repo": return try await createRepo(argumentsJSON: argumentsJSON, token: token, subpath: subpath)
        default: throw PluginRegistry.PluginError.unknownTool(name)
        }
    }

    func executeToolStreaming(
        name: String,
        argumentsJSON: String,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        guard let token = cachedToken else {
            return ToolResult(text: "Not authenticated. Please sign in with GitHub in Settings.")
        }
        let subpath = (try? parseArg(argumentsJSON, key: "path", default: nil)) ?? nil
        switch name {
        case "github_clone":
            return try await cloneStreaming(argumentsJSON: argumentsJSON, token: token, progressHandler: progressHandler)
        default:
            return try await executeTool(name: name, argumentsJSON: argumentsJSON)
        }
    }

    private func cloneStreaming(argumentsJSON: String, token: String, progressHandler: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let repoURLString = try parseArg(argumentsJSON, key: "repo_url")
        let depth = intArg(argumentsJSON, key: "depth", default: 1)
        guard let wsURL = WorkspaceManager.shared.currentURL else {
            return ToolResult(text: "No workspace selected.")
        }
        let remoteURL: URL
        switch Self.validatedGitHubRemoteURL(from: repoURLString) {
        case .failure(let error):
            return ToolResult(text: error.message)
        case .success(let url):
            remoteURL = url
        }
        let repoName = remoteURL.lastPathComponent.replacingOccurrences(of: ".git", with: "")
        let dest = wsURL.appendingPathComponent(repoName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            return ToolResult(text: "Directory already exists: \(repoName)/")
        }

        let securityOK = wsURL.startAccessingSecurityScopedResource()
        defer {
            if securityOK {
                wsURL.stopAccessingSecurityScopedResource()
            }
        }

        var pendingResult: ToolResult?

        let stream = AsyncStream<String> { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let checkoutProgress: CheckoutProgressBlock = { path, completed, total in
                    if total > 0 {
                        let file = path.map { $0.split(separator: "/").last.map(String.init) ?? "" } ?? ""
                        let pct = completed * 100 / total
                        let label = file.isEmpty ? "Checkout \(pct)%" : "Checkout \(file) \(pct)%"
                        DispatchQueue.main.async { progressHandler(label) }
                        continuation.yield(label)
                    }
                }
                let creds = Credentials.plaintext(username: "x-access-token", password: token)
                let result = Repository.clone(from: remoteURL, to: dest, depth: depth, credentials: creds, checkoutStrategy: .Force, checkoutProgress: checkoutProgress)
                switch result {
                case .success:
                    let text = "Cloned into \(repoName)/"
                    DispatchQueue.main.async { progressHandler("Done.") }
                    continuation.yield("Done.")
                    pendingResult = ToolResult(text: text)
                case .failure(let e):
                    try? FileManager.default.removeItem(at: dest)
                    let label = "Failed: \(e.localizedDescription)"
                    DispatchQueue.main.async { progressHandler(label) }
                    continuation.yield(label)
                    pendingResult = ToolResult(text: label)
                }
                continuation.finish()
            }
        }

        for await _ in stream {}
        return pendingResult ?? ToolResult(text: "Clone failed: unknown error")
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

    private func findGitRepoURL(subpath: String? = nil) -> URL? {
        guard let wsURL = WorkspaceManager.shared.currentURL else { return nil }
        var isDir: ObjCBool = false
        if let subpath, !subpath.isEmpty {
            let target = wsURL.appendingPathComponent(subpath)
            if FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path, isDirectory: &isDir), isDir.boolValue {
                return target
            }
            return nil
        }
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

    nonisolated private static func validatedGitHubRemoteURL(from string: String) -> Result<URL, ValidationError> {
        guard let remoteURL = URL(string: string),
              let scheme = remoteURL.scheme?.lowercased(),
              let host = remoteURL.host?.lowercased() else {
            return .failure(ValidationError(message: "Invalid URL: \(string)"))
        }
        guard scheme == "https" else {
            return .failure(ValidationError(message: "Only https:// GitHub repository URLs are allowed."))
        }
        guard Self.allowedGitHubHosts.contains(host) else {
            return .failure(ValidationError(message: "Only github.com repository URLs are allowed."))
        }
        guard remoteURL.user == nil, remoteURL.password == nil else {
            return .failure(ValidationError(message: "Repository URL must not include embedded credentials."))
        }
        let path = remoteURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else {
            return .failure(ValidationError(message: "Repository URL must include owner and repository name."))
        }
        return .success(remoteURL)
    }

    nonisolated private static func validatedOriginRemote(in repo: Repository) -> Result<Remote, ValidationError> {
        switch repo.remote(named: "origin") {
        case .failure(let error):
            return .failure(ValidationError(message: "No remote 'origin': \(error.localizedDescription)"))
        case .success(let remote):
            switch Self.validatedGitHubRemoteURL(from: remote.URL) {
            case .failure(let error):
                return .failure(ValidationError(message: "Origin remote is not an allowed GitHub HTTPS URL. \(error.message)"))
            case .success:
                return .success(remote)
            }
        }
    }

    nonisolated private static func sanitizedRemoteURL(_ string: String) -> String {
        guard var components = URLComponents(string: string),
              components.user != nil || components.password != nil else {
            return string
        }
        components.user = nil
        components.password = nil
        return components.string ?? string
    }

    private func withRepo(subpath: String? = nil, _ body: @Sendable @escaping (Repository) -> ToolResult) async -> ToolResult {
        guard let repoURL = findGitRepoURL(subpath: subpath) else {
            return ToolResult(text: "Current workspace is not a git repository.")
        }
        let wsURL = WorkspaceManager.shared.currentURL
        let securityOK = wsURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if securityOK { wsURL?.stopAccessingSecurityScopedResource() }
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
        let depth = intArg(argumentsJSON, key: "depth", default: 1)
        guard let wsURL = WorkspaceManager.shared.currentURL else {
            return ToolResult(text: "No workspace selected.")
        }
        let remoteURL: URL
        switch Self.validatedGitHubRemoteURL(from: repoURLString) {
        case .failure(let error):
            return ToolResult(text: error.message)
        case .success(let url):
            remoteURL = url
        }
        let repoName = remoteURL.lastPathComponent.replacingOccurrences(of: ".git", with: "")
        let dest = wsURL.appendingPathComponent(repoName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            return ToolResult(text: "Directory already exists: \(repoName)/")
        }

        let securityOK = wsURL.startAccessingSecurityScopedResource()
        defer {
            if securityOK {
                wsURL.stopAccessingSecurityScopedResource()
            }
        }

        let progressText = LockedValue<String>("Fetching objects…")

        return await withCheckedContinuation { continuation in
            let creds = Credentials.plaintext(username: "x-access-token", password: token)
            DispatchQueue.global(qos: .userInitiated).async {
                let checkoutProgress: CheckoutProgressBlock = { path, completed, total in
                    if total > 0 {
                        let file = path.map { $0.split(separator: "/").last.map(String.init) ?? "" } ?? ""
                        let pct = completed * 100 / total
                        let label = file.isEmpty ? "Checkout \(pct)%" : "Checkout \(file) \(pct)%"
                        progressText.value = label
                    }
                }
                switch Repository.clone(from: remoteURL, to: dest, depth: depth, credentials: creds, checkoutStrategy: .Force, checkoutProgress: checkoutProgress) {
                case .success:
                    continuation.resume(returning: ToolResult(text: "Cloned into \(repoName)/ — \(progressText.value)"))
                case .failure(let e):
                    try? FileManager.default.removeItem(at: dest)
                    continuation.resume(returning: ToolResult(text: "Clone failed (\(progressText.value)): \(e.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - Push

    private func push(argumentsJSON: String, token: String, subpath: String? = nil) async throws -> ToolResult {
        let message = try parseArg(argumentsJSON, key: "message")
        let branch: String? = try? parseArg(argumentsJSON, key: "branch")
        guard let repoURL = findGitRepoURL(subpath: subpath) else {
            return ToolResult(text: "Not a git repository. Clone or create one first.")
        }
        let wsURL = WorkspaceManager.shared.currentURL
        let securityOK = wsURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if securityOK { wsURL?.stopAccessingSecurityScopedResource() }
        }
        return await withCheckedContinuation { continuation in
            let creds = Credentials.plaintext(username: "x-access-token", password: token)
            DispatchQueue.global(qos: .userInitiated).async {
                switch Repository.at(repoURL) {
                case .failure(let e):
                    continuation.resume(returning: ToolResult(text: "Open failed: \(e.localizedDescription)"))
                case .success(let repo):
                    switch Self.validatedOriginRemote(in: repo) {
                    case .failure(let error):
                        continuation.resume(returning: ToolResult(text: error.message))
                        return
                    case .success:
                        break
                    }
                    let _ = repo.add(path: ".")
                    let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
                    switch repo.commit(message: message, signature: sig) {
                    case .failure(let e):
                        continuation.resume(returning: ToolResult(text: "Commit failed: \(e.localizedDescription)"))
                    case .success(let commit):
                        let pushResult = repo.push(credentials: creds, branch: branch)
                        switch pushResult {
                        case .failure(let e):
                            continuation.resume(returning: ToolResult(text: "Push failed: \(e.localizedDescription)"))
                        case .success:
                            let short = String(commit.oid.description.prefix(7))
                            continuation.resume(returning: ToolResult(text: "Pushed \(short): \(message)"))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pull

    private func pull(token: String, subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
            let creds = Credentials.plaintext(username: "x-access-token", password: token)
            switch Self.validatedOriginRemote(in: repo) {
            case .failure(let error): return ToolResult(text: error.message)
            case .success(let remote):
                // Fetch current branch and explicitly update remote tracking ref
                let refspec = "+refs/heads/main:refs/remotes/origin/main"
                let fetchResult = repo.fetch(remote, refspecs: [refspec], credentials: creds)
                switch fetchResult {
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

    private func fetch(token: String, subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
            let creds = Credentials.plaintext(username: "x-access-token", password: token)
            switch Self.validatedOriginRemote(in: repo) {
            case .failure(let error): return ToolResult(text: error.message)
            case .success(let remote):
                let fetchResult = repo.fetch(remote, credentials: creds)
                switch fetchResult {
                case .failure(let e): return ToolResult(text: "Fetch failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "Fetched latest objects from origin.")
                }
            }
        }
    }

    // MARK: - Status

    private func status(subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
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

    private func log(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let count = intArg(argumentsJSON, key: "count", default: 10)
        return await withRepo(subpath: subpath) { repo in
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
                    lines.append("\(oid) \(c.author.name) \(date)\n    \(msg)")
                    n += 1
                }
                return ToolResult(text: lines.isEmpty ? "No commits." : lines.joined(separator: "\n\n"))
            }
        }
    }

    // MARK: - Diff

    private func diff(subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
            switch repo.HEAD() {
            case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
            case .success(let ref):
                guard let commit = ref as? Commit else { return ToolResult(text: "HEAD is not a commit.") }
                switch repo.diff(for: commit) {
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

    private func branchList(subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
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

    private func branchCheckout(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let branch = try parseArg(argumentsJSON, key: "branch")
        return await withRepo(subpath: subpath) { repo in
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

     private func branchCreate(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
         let branchName = try parseArg(argumentsJSON, key: "branch")
         return await withRepo(subpath: subpath) { repo in
             switch repo.localBranch(named: branchName) {
             case .success(let b):
                 switch repo.checkout(b, strategy: .Force) {
                 case .failure(let e): return ToolResult(text: "Checkout failed: \(e.localizedDescription)")
                 case .success: return ToolResult(text: "Switched to existing branch '\(branchName)'.")
                 }
             case .failure:
                 var headObj: OpaquePointer?
                 let headResult = git_revparse_single(&headObj, repo.pointer, "HEAD")
                 guard headResult == GIT_OK.rawValue, headObj != nil else {
                     return ToolResult(text: "Cannot resolve HEAD (error \(headResult)).")
                 }

                 var commitObj: OpaquePointer?
                 if git_object_type(headObj) == GIT_OBJECT_COMMIT {
                     commitObj = headObj
                 } else {
                     let peelResult = git_object_peel(&commitObj, headObj, GIT_OBJECT_COMMIT)
                     git_object_free(headObj)
                     guard peelResult == GIT_OK.rawValue, commitObj != nil else {
                         return ToolResult(text: "HEAD does not point to a commit (error \(peelResult)).")
                     }
                 }
                 defer { git_object_free(commitObj) }

                 var refOut: OpaquePointer?
                 let branchResult = branchName.withCString { namePtr in
                     git_branch_create(&refOut, repo.pointer, namePtr, commitObj, 0)
                 }
                 guard branchResult == GIT_OK.rawValue, refOut != nil else {
                     let errPtr = git_error_last()
                     let errMsg = errPtr != nil ? String(validatingUTF8: errPtr!.pointee.message) ?? "unknown" : "unknown"
                     return ToolResult(text: "Branch create failed (error \(branchResult)): \(errMsg)")
                 }
                 git_reference_free(refOut)
                 switch repo.localBranch(named: branchName) {
                 case .success(let b):
                     switch repo.checkout(b, strategy: .Force) {
                     case .failure(let e): return ToolResult(text: "Checkout failed: \(e.localizedDescription)")
                     case .success: return ToolResult(text: "Created and switched to branch '\(branchName)'.")
                     }
                 case .failure(let e):
                     return ToolResult(text: "Branch created but checkout failed: \(e.localizedDescription)")
                 }
             }
         }
     }

    // MARK: - Remote List

    private func remoteList(subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
            switch repo.allRemotes() {
            case .failure(let e): return ToolResult(text: "Failed: \(e.localizedDescription)")
            case .success(let remotes):
                if remotes.isEmpty { return ToolResult(text: "No remotes configured.") }
                return ToolResult(text: remotes.map { "\($0.name)  \(Self.sanitizedRemoteURL($0.URL))" }.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Tag List

    private func tagList(subpath: String? = nil) async throws -> ToolResult {
        await withRepo(subpath: subpath) { repo in
            switch repo.allTags() {
            case .failure(let e): return ToolResult(text: "Failed: \(e.localizedDescription)")
            case .success(let tags):
                if tags.isEmpty { return ToolResult(text: "No tags.") }
                return ToolResult(text: tags.map { $0.name }.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Reset

    private func reset(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let target = (try? parseArg(argumentsJSON, key: "target", default: "HEAD")) ?? "HEAD"
        let modeStr = (try? parseArg(argumentsJSON, key: "mode", default: "mixed")) ?? "mixed"
        let paths: [String]? = {
            guard let data = argumentsJSON.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = args["paths"] as? [String], !arr.isEmpty else { return nil }
            return arr
        }()

        let resetType: Repository.ResetType
        switch modeStr.lowercased() {
        case "soft": resetType = .soft
        case "mixed": resetType = .mixed
        case "hard": resetType = .hard
        default: return ToolResult(text: "Invalid mode '\(modeStr)'. Use 'soft', 'mixed', or 'hard'.")
        }

        return await withRepo(subpath: subpath) { repo in
            if let paths {
                let targetOID: OID?
                if target == "HEAD" || target.isEmpty {
                    switch repo.HEAD() {
                    case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
                    case .success(let ref): targetOID = ref.oid
                    }
                } else {
                    switch repo.resolveRevision(target) {
                    case .failure(let e): return ToolResult(text: "Cannot resolve '\(target)': \(e.localizedDescription)")
                    case .success(let oid): targetOID = oid
                    }
                }
                switch repo.resetDefault(targetOID, paths: paths) {
                case .failure(let e): return ToolResult(text: "Reset failed: \(e.localizedDescription)")
                case .success:
                    let fileList = paths.count <= 5 ? paths.joined(separator: ", ") : "\(paths.prefix(5).joined(separator: ", ")) and \(paths.count - 5) more"
                    return ToolResult(text: "Unstaged \(fileList).")
                }
            }

            let targetOID: OID
            if target == "HEAD" || target.isEmpty {
                switch repo.HEAD() {
                case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
                case .success(let ref): targetOID = ref.oid
                }
            } else {
                switch repo.resolveRevision(target) {
                case .failure(let e):
                    switch repo.localBranch(named: target) {
                    case .success(let branch): targetOID = branch.oid
                    case .failure:
                        switch repo.tag(named: target) {
                        case .success(let tagRef): targetOID = tagRef.oid
                        case .failure: return ToolResult(text: "Cannot resolve '\(target)': \(e.localizedDescription)")
                        }
                    }
                case .success(let oid): targetOID = oid
                }
            }

            let targetShort = String(targetOID.description.prefix(7))
            switch repo.reset(targetOID, resetType: resetType) {
            case .failure(let e): return ToolResult(text: "Reset failed: \(e.localizedDescription)")
            case .success:
                let modeLabel = resetType == .soft ? "soft" : resetType == .mixed ? "mixed" : "hard"
                return ToolResult(text: "HEAD is now at \(targetShort) (\(modeLabel) reset).")
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
            let priv = repo["private"] as? Bool == true ? "private" : "public"
            let desc = repo["description"] as? String ?? ""
            return "[\(priv)] \(name)\(desc.isEmpty ? "" : " — \(desc)")"
        }
        return ToolResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - Create Repo (GitHub API)

    private func createRepo(argumentsJSON: String, token: String, subpath: String? = nil) async throws -> ToolResult {
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

        let securityOK = wsURL.startAccessingSecurityScopedResource()
        defer {
            if securityOK { wsURL.stopAccessingSecurityScopedResource() }
        }

        let initOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: Repository.create(at: wsURL).isSuccess) }
        }
        guard initOK else { return ToolResult(text: "Repository created: \(htmlURL)\nGit init failed.") }

        let remoteStr = "https://github.com/\(fullName).git"
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
        let pushResult = try await push(argumentsJSON: String(data: pushJSON, encoding: .utf8)!, token: token, subpath: subpath)
        return ToolResult(text: "Created and pushed: \(htmlURL)\n\(pushResult.text)")
    }

    // MARK: - Add

    private func addFiles(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let paths: [String] = {
            guard let data = argumentsJSON.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = args["paths"] as? [String], !arr.isEmpty else { return [] }
            return arr
        }()
        guard !paths.isEmpty else { return ToolResult(text: "No paths specified.") }
        return await withRepo(subpath: subpath) { repo in
            for p in paths {
                switch repo.add(path: p) {
                case .failure(let e): return ToolResult(text: "Add failed for '\(p)': \(e.localizedDescription)")
                case .success: continue
                }
            }
            return ToolResult(text: "Staged \(paths.count) file(s).")
        }
    }

    // MARK: - Commit Only

    private func commitOnly(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let message = try parseArg(argumentsJSON, key: "message")
        return await withRepo(subpath: subpath) { repo in
            let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
            switch repo.commit(message: message, signature: sig) {
            case .failure(let e): return ToolResult(text: "Commit failed: \(e.localizedDescription)")
            case .success(let c):
                let short = String(c.oid.description.prefix(7))
                return ToolResult(text: "Committed \(short): \(message)")
            }
        }
    }

    // MARK: - Show

    private func show(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let revision = (try? parseArg(argumentsJSON, key: "revision", default: "HEAD")) ?? "HEAD"
        return await withRepo(subpath: subpath) { repo in
            let oid: OID
            if revision == "HEAD" || revision.isEmpty {
                switch repo.HEAD() {
                case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
                case .success(let ref): oid = ref.oid
                }
            } else {
                switch repo.resolveRevision(revision) {
                case .failure(let e):
                    switch repo.localBranch(named: revision) {
                    case .success(let b): oid = b.oid
                    case .failure: return ToolResult(text: "Cannot resolve '\(revision)': \(e.localizedDescription)")
                    }
                case .success(let o): oid = o
                }
            }
            switch repo.show(oid: oid) {
            case .failure(let e): return ToolResult(text: "Show failed: \(e.localizedDescription)")
            case .success(let detail):
                var lines: [String] = []
                let short = String(detail.oid.description.prefix(7))
                lines.append("commit \(short)")
                lines.append("Author: \(detail.author.name) <\(detail.author.email)>")
                lines.append("Date:   \(ISO8601DateFormatter().string(from: detail.author.time))")
                if !detail.parentOIDs.isEmpty {
                    lines.append("Parents: \(detail.parentOIDs.joined(separator: " "))")
                }
                lines.append("")
                for line in detail.message.split(separator: "\n") {
                    lines.append("    \(line)")
                }
                if !detail.diff.isEmpty {
                    lines.append("")
                    lines.append("Changes:")
                    lines.append(detail.diff)
                }
                return ToolResult(text: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Stash

    private func stash(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let action = (try? parseArg(argumentsJSON, key: "action", default: "save")) ?? "save"
        let message = try? parseArg(argumentsJSON, key: "message", default: nil)
        let index = intArg(argumentsJSON, key: "index", default: 0)
        let includeUntracked = boolArg(argumentsJSON, key: "include_untracked", default: true)

        return await withRepo(subpath: subpath) { repo in
            switch action.lowercased() {
            case "list":
                switch repo.stashList() {
                case .failure(let e): return ToolResult(text: "Stash list failed: \(e.localizedDescription)")
                case .success(let entries):
                    if entries.isEmpty { return ToolResult(text: "No stash entries.") }
                    let lines = entries.map { e in
                        let short = String(e.oid.description.prefix(7))
                        return "stash@{\(e.index)}: \(short) \(e.message)"
                    }
                    return ToolResult(text: lines.joined(separator: "\n"))
                }
            case "save":
                let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
                switch repo.stashSave(message: message, signature: sig, includeUntracked: includeUntracked) {
                case .failure(let e): return ToolResult(text: "Stash failed: \(e.localizedDescription)")
                case .success(let oid):
                    let short = String(oid.description.prefix(7))
                    return ToolResult(text: "Saved stash \(short).")
                }
            case "apply":
                switch repo.stashApply(index: index, reinstateIndex: false) {
                case .failure(let e): return ToolResult(text: "Stash apply failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "Applied stash@{\(index)}.")
                }
            case "pop":
                switch repo.stashPop(index: index, reinstateIndex: false) {
                case .failure(let e): return ToolResult(text: "Stash pop failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "Popped stash@{\(index)}.")
                }
            case "drop":
                switch repo.stashDrop(index: index) {
                case .failure(let e): return ToolResult(text: "Stash drop failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "Dropped stash@{\(index)}.")
                }
            default:
                return ToolResult(text: "Unknown stash action '\(action)'. Use: save, list, apply, pop, drop.")
            }
        }
    }

    // MARK: - Merge

    private func merge(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let branch = try parseArg(argumentsJSON, key: "branch")
        let message = try? parseArg(argumentsJSON, key: "message", default: nil)
        return await withRepo(subpath: subpath) { repo in
            switch repo.merge(branch: branch) {
            case .failure(let e): return ToolResult(text: "Merge failed: \(e.localizedDescription)")
            case .success(let result):
                if result.hasConflicts {
                    return ToolResult(text: "Merged with conflicts. Resolve conflicts, then commit.")
                }
                let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
                let msg = message ?? "Merge branch '\(branch)'"
                switch repo.commit(message: msg, signature: sig) {
                case .failure(let e): return ToolResult(text: "Merge commit failed: \(e.localizedDescription)")
                case .success(let c):
                    let short = String(c.oid.description.prefix(7))
                    _ = repo.stateCleanup()
                    return ToolResult(text: "Merged '\(branch)' as \(short).")
                }
            }
        }
    }

    // MARK: - Cherry-pick

    private func cherryPick(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let commitStr = try parseArg(argumentsJSON, key: "commit")
        return await withRepo(subpath: subpath) { repo in
            let oid: OID
            switch repo.resolveRevision(commitStr) {
            case .success(let o): oid = o
            case .failure(let e): return ToolResult(text: "Cannot resolve '\(commitStr)': \(e.localizedDescription)")
            }
            switch repo.cherryPick(commitOID: oid) {
            case .failure(let e): return ToolResult(text: "Cherry-pick failed: \(e.localizedDescription)")
            case .success(let hasConflicts):
                if hasConflicts {
                    return ToolResult(text: "Cherry-pick applied with conflicts. Resolve and commit.")
                }
                let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
                let short = String(oid.description.prefix(7))
                switch repo.commit(message: "Cherry-pick \(short)", signature: sig) {
                case .failure(let e): return ToolResult(text: "Cherry-pick commit failed: \(e.localizedDescription)")
                case .success(let c):
                    let newShort = String(c.oid.description.prefix(7))
                    _ = repo.stateCleanup()
                    return ToolResult(text: "Cherry-picked \(short) as \(newShort).")
                }
            }
        }
    }

    // MARK: - Revert

    private func revert(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let commitStr = try parseArg(argumentsJSON, key: "commit")
        return await withRepo(subpath: subpath) { repo in
            let oid: OID
            switch repo.resolveRevision(commitStr) {
            case .success(let o): oid = o
            case .failure(let e): return ToolResult(text: "Cannot resolve '\(commitStr)': \(e.localizedDescription)")
            }
            switch repo.revert(commitOID: oid) {
            case .failure(let e): return ToolResult(text: "Revert failed: \(e.localizedDescription)")
            case .success(let hasConflicts):
                if hasConflicts {
                    return ToolResult(text: "Revert applied with conflicts. Resolve and commit.")
                }
                let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
                let short = String(oid.description.prefix(7))
                switch repo.commit(message: "Revert \(short)", signature: sig) {
                case .failure(let e): return ToolResult(text: "Revert commit failed: \(e.localizedDescription)")
                case .success(let c):
                    let newShort = String(c.oid.description.prefix(7))
                    _ = repo.stateCleanup()
                    return ToolResult(text: "Reverted \(short) as \(newShort).")
                }
            }
        }
    }

    // MARK: - Branch Delete

    private func branchDelete(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let branch = try parseArg(argumentsJSON, key: "branch")
        return await withRepo(subpath: subpath) { repo in
            switch repo.deleteBranch(named: branch) {
            case .failure(let e): return ToolResult(text: "Delete failed: \(e.localizedDescription)")
            case .success: return ToolResult(text: "Deleted branch '\(branch)'.")
            }
        }
    }

    // MARK: - Tag Create

    private func tagCreate(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let tagName = try parseArg(argumentsJSON, key: "name")
        let target = (try? parseArg(argumentsJSON, key: "target", default: "HEAD")) ?? "HEAD"
        let message = try? parseArg(argumentsJSON, key: "message", default: nil)
        return await withRepo(subpath: subpath) { repo in
            let oid: OID
            if target == "HEAD" || target.isEmpty {
                switch repo.HEAD() {
                case .failure(let e): return ToolResult(text: "HEAD failed: \(e.localizedDescription)")
                case .success(let ref): oid = ref.oid
                }
            } else {
                switch repo.resolveRevision(target) {
                case .failure(let e): return ToolResult(text: "Cannot resolve '\(target)': \(e.localizedDescription)")
                case .success(let o): oid = o
                }
            }
            let sig = Signature(name: "CopilotChat", email: "copilotchat@users.noreply.github.com")
            switch repo.createTag(name: tagName, targetOID: oid, message: message, tagger: sig) {
            case .failure(let e): return ToolResult(text: "Tag create failed: \(e.localizedDescription)")
            case .success:
                let tagType = message != nil ? "Annotated tag" : "Lightweight tag"
                return ToolResult(text: "\(tagType) '\(tagName)' created at \(String(oid.description.prefix(7))).")
            }
        }
    }

    // MARK: - Tag Delete

    private func tagDelete(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let tagName = try parseArg(argumentsJSON, key: "name")
        return await withRepo(subpath: subpath) { repo in
            switch repo.deleteTag(named: tagName) {
            case .failure(let e): return ToolResult(text: "Tag delete failed: \(e.localizedDescription)")
            case .success: return ToolResult(text: "Deleted tag '\(tagName)'.")
            }
        }
    }

    // MARK: - Remote Add

    private func remoteAdd(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let name = try parseArg(argumentsJSON, key: "name")
        let url = try parseArg(argumentsJSON, key: "url")
        return await withRepo(subpath: subpath) { repo in
            switch repo.addRemote(name: name, url: url) {
            case .failure(let e): return ToolResult(text: "Remote add failed: \(e.localizedDescription)")
            case .success: return ToolResult(text: "Added remote '\(name)' -> \(url).")
            }
        }
    }

    // MARK: - Remote Remove

    private func remoteRemove(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let name = try parseArg(argumentsJSON, key: "name")
        return await withRepo(subpath: subpath) { repo in
            switch repo.removeRemote(name: name) {
            case .failure(let e): return ToolResult(text: "Remote remove failed: \(e.localizedDescription)")
            case .success: return ToolResult(text: "Removed remote '\(name)'.")
            }
        }
    }

    // MARK: - Remove Files

    private func removeFiles(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let paths: [String] = {
            guard let data = argumentsJSON.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = args["paths"] as? [String], !arr.isEmpty else { return [] }
            return arr
        }()
        guard !paths.isEmpty else { return ToolResult(text: "No paths specified.") }
        return await withRepo(subpath: subpath) { repo in
            switch repo.remove(paths: paths) {
            case .failure(let e): return ToolResult(text: "Remove failed: \(e.localizedDescription)")
            case .success:
                let fileList = paths.count <= 5 ? paths.joined(separator: ", ") : "\(paths.prefix(5).joined(separator: ", ")) and \(paths.count - 5) more"
                return ToolResult(text: "Removed \(paths.count) file(s): \(fileList)")
            }
        }
    }

    // MARK: - Blame

    private func blame(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let file = try parseArg(argumentsJSON, key: "file")
        let revision = try? parseArg(argumentsJSON, key: "revision", default: nil)
        return await withRepo(subpath: subpath) { repo in
            let commitOID: OID? = revision.flatMap { rev in
                switch repo.resolveRevision(rev) {
                case .success(let o): return o
                case .failure: return nil
                }
            }
            switch repo.blame(path: file, commitOID: commitOID) {
            case .failure(let e): return ToolResult(text: "Blame failed: \(e.localizedDescription)")
            case .success(let hunks):
                if hunks.isEmpty { return ToolResult(text: "No blame data for '\(file)'.") }
                var lines: [String] = []
                for h in hunks {
                    let short = h.finalCommitOID.map { String($0.description.prefix(7)) } ?? "-------"
                    let name = h.author.name
                    lines.append("\(short) \(name) (\(h.finalStartLineNumber)) [\(h.linesInHunk) lines]")
                }
                return ToolResult(text: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Reflog

    private func reflog(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let ref = (try? parseArg(argumentsJSON, key: "ref", default: "HEAD")) ?? "HEAD"
        let count = intArg(argumentsJSON, key: "count", default: 20)
        return await withRepo(subpath: subpath) { repo in
            switch repo.reflog(reference: ref) {
            case .failure(let e): return ToolResult(text: "Reflog failed: \(e.localizedDescription)")
            case .success(let entries):
                if entries.isEmpty { return ToolResult(text: "No reflog entries.") }
                let limited = Array(entries.prefix(count))
                let lines = limited.enumerated().map { i, e in
                    let old = String(e.oldOID.description.prefix(7))
                    let new = String(e.newOID.description.prefix(7))
                    let msg = e.message.isEmpty ? "" : " \(e.message)"
                    return "\(i) \(old) -> \(new)\(msg) (\(e.committer.name))"
                }
                return ToolResult(text: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Clean

    private func clean(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let directories = boolArg(argumentsJSON, key: "directories", default: false)
        return await withRepo(subpath: subpath) { repo in
            switch repo.clean(directories: directories) {
            case .failure(let e): return ToolResult(text: "Clean failed: \(e.localizedDescription)")
            case .success(let count):
                if count == 0 { return ToolResult(text: "Nothing to clean.") }
                let suffix = directories ? " files and directories" : " files"
                return ToolResult(text: "Removed \(count) untracked\(suffix).")
            }
        }
    }

    // MARK: - Describe

    private func describe(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let revision = try? parseArg(argumentsJSON, key: "revision", default: nil)
        return await withRepo(subpath: subpath) { repo in
            let oid: OID? = revision.flatMap { rev in
                switch repo.resolveRevision(rev) {
                case .success(let o): return o
                case .failure: return nil
                }
            }
            switch repo.describe(commitOID: oid) {
            case .failure(let e): return ToolResult(text: "Describe failed: \(e.localizedDescription)")
            case .success(let description):
                return ToolResult(text: description)
            }
        }
    }

    // MARK: - Config

    private func config(argumentsJSON: String, subpath: String? = nil) async throws -> ToolResult {
        let key = try parseArg(argumentsJSON, key: "key")
        let value = try? parseArg(argumentsJSON, key: "value", default: nil)
        return await withRepo(subpath: subpath) { repo in
            if let value {
                switch repo.setConfig(key, value: value) {
                case .failure(let e): return ToolResult(text: "Config set failed: \(e.localizedDescription)")
                case .success: return ToolResult(text: "\(key) = \(value)")
                }
            } else {
                switch repo.getConfig(key) {
                case .failure(let e): return ToolResult(text: "Config get failed: \(e.localizedDescription)")
                case .success(let val): return ToolResult(text: "\(key) = \(val)")
                }
            }
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    init(_ value: T) { _value = value }
}

private final class UnsafeContinuationHolder<T>: @unchecked Sendable {
    var continuation: CheckedContinuation<T, Never>?
}
