import Foundation

#if os(macOS)
@MainActor
final class TerminalPlugin: Plugin {
    let id = "com.copilotchat.terminal"
    let name = "Terminal"
    let version = "1.0.0"

    func configure(with input: PluginInput) async throws -> PluginHooks {
        let tools = [
            MCPTool(
                name: "bash",
                description: "Execute a shell command in the selected workspace and stream terminal output. Use this for git, npm, xcodebuild, ls, and other CLI workflows when coding on macOS.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "command": [
                            "type": "string",
                            "description": "Shell command to execute in zsh."
                        ] as [String: Any],
                        "workdir": [
                            "type": "string",
                            "description": "Optional path relative to the workspace root. Defaults to the workspace root."
                        ] as [String: Any],
                        "timeout": [
                            "type": "integer",
                            "description": "Optional timeout in milliseconds. Defaults to 120000."
                        ] as [String: Any],
                        "description": [
                            "type": "string",
                            "description": "Short human-readable description of what the command does."
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["command"]),
                ],
                serverName: name
            ),
        ]

        return PluginHooks(
            tools: tools,
            onExecute: { [weak self] toolName, argumentsJSON in
                guard let self else { return ToolResult(text: "Plugin unavailable") }
                return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
            },
            onExecuteStreaming: { [weak self] toolName, argumentsJSON, progressHandler in
                guard let self else { return ToolResult(text: "Plugin unavailable") }
                return try await self.executeToolStreaming(name: toolName, argumentsJSON: argumentsJSON, progressHandler: progressHandler)
            }
        )
    }

    private struct CommandRequest {
        let command: String
        let workdir: String
        let timeoutMs: UInt64
        let summary: String?
    }

    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        switch name {
        case "bash":
            return try await runBash(argumentsJSON: argumentsJSON, progressHandler: nil)
        default:
            throw PluginRegistry.PluginError.unknownTool(name)
        }
    }

    private func executeToolStreaming(
        name: String,
        argumentsJSON: String,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        switch name {
        case "bash":
            return try await runBash(argumentsJSON: argumentsJSON, progressHandler: progressHandler)
        default:
            throw PluginRegistry.PluginError.unknownTool(name)
        }
    }

    private func runBash(
        argumentsJSON: String,
        progressHandler: (@Sendable (String) -> Void)?
    ) async throws -> ToolResult {
        guard WorkspaceManager.shared.hasWorkspace,
              let workspaceURL = WorkspaceManager.shared.currentURL else {
            return ToolResult(text: "No workspace selected. Please select a project folder first.")
        }

        let request = try parse(argumentsJSON: argumentsJSON)
        let workingURL = resolveWorkingDirectory(workspaceURL: workspaceURL, workdir: request.workdir)

        let securityOK = workspaceURL.startAccessingSecurityScopedResource()
        defer {
            if securityOK {
                workspaceURL.stopAccessingSecurityScopedResource()
            }
        }

        let output = try await runProcess(
            command: request.command,
            workingDirectory: workingURL,
            timeoutMs: request.timeoutMs,
            progressHandler: progressHandler
        )

        return ToolResult(text: output)
    }

    private func parse(argumentsJSON: String) throws -> CommandRequest {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = args["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidArguments("bash requires a non-empty 'command' string argument")
        }

        let workdir = (args["workdir"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "."
        let timeout = UInt64(max(args["timeout"] as? Int ?? 120_000, 1))
        let summary = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return CommandRequest(command: command, workdir: workdir.isEmpty ? "." : workdir, timeoutMs: timeout, summary: summary)
    }

    private func resolveWorkingDirectory(workspaceURL: URL, workdir: String) -> URL {
        if workdir == "." { return workspaceURL }
        if let resolved = WorkspaceManager.shared.resolvePathPublic(workdir) {
            return resolved
        }
        return workspaceURL.appendingPathComponent(workdir)
    }

    private func runProcess(
        command: String,
        workingDirectory: URL,
        timeoutMs: UInt64,
        progressHandler: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = TerminalOutputCollector(progressHandler: progressHandler)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collector.consume(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collector.consume(data)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                timeoutTask.cancel()

                collector.finishRemainingOutput(handles: [stdout.fileHandleForReading, stderr.fileHandleForReading])

                let output = collector.output
                let exitCode = process.terminationStatus
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: output + (output.isEmpty ? "" : "\n") + "Process terminated by signal.")
                } else if exitCode == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(returning: output + (output.isEmpty ? "" : "\n") + "Exit code: \(exitCode)")
                }
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                timeoutTask.cancel()
                continuation.resume(throwing: error)
                return
            }
        }
    }
}

private final class TerminalOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let progressHandler: (@Sendable (String) -> Void)?

    init(progressHandler: (@Sendable (String) -> Void)?) {
        self.progressHandler = progressHandler
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        buffer.append(data)
        lock.unlock()
        if !text.isEmpty {
            DispatchQueue.main.async {
                self.progressHandler?(text)
            }
        }
    }

    func finishRemainingOutput(handles: [FileHandle]) {
        for handle in handles {
            let data = handle.readDataToEndOfFile()
            consume(data)
            try? handle.close()
        }
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
#endif
