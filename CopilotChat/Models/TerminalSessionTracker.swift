import Foundation
import SwiftUI

enum TerminalSessionState: Equatable {
    case running
    case completed(exitCode: Int32)
    case failed(String)
    case cancelled
}

@Observable
@MainActor
final class TerminalSessionTracker {
    static let shared = TerminalSessionTracker()

    struct TerminalSession: Identifiable {
        let id: String
        let toolCallId: String
        let command: String
        let workingDirectory: String
        let startedAt: Date
        var output: String
        var statusLine: String
        var state: TerminalSessionState

        init(
            id: String,
            toolCallId: String,
            command: String,
            workingDirectory: String,
            startedAt: Date = Date()
        ) {
            self.id = id
            self.toolCallId = toolCallId
            self.command = command
            self.workingDirectory = workingDirectory
            self.startedAt = startedAt
            self.output = ""
            self.statusLine = "Starting…"
            self.state = .running
        }
    }

    private(set) var sessions: [String: TerminalSession] = [:]
    var focusedSessionId: String?
    var isWindowPresented = false

    private init() {}

    func startSession(toolCallId: String, command: String, workingDirectory: String) -> String {
        let id = UUID().uuidString
        sessions[toolCallId] = TerminalSession(
            id: id,
            toolCallId: toolCallId,
            command: command,
            workingDirectory: workingDirectory
        )
        return id
    }

    func appendOutput(_ chunk: String, forToolCallId toolCallId: String) {
        guard !chunk.isEmpty else { return }
        sessions[toolCallId]?.output += chunk
    }

    func updateStatus(_ status: String, forToolCallId toolCallId: String) {
        sessions[toolCallId]?.statusLine = status
    }

    func complete(toolCallId: String, output: String, exitCode: Int32) {
        sessions[toolCallId]?.output = output
        sessions[toolCallId]?.statusLine = exitCode == 0 ? "Completed" : "Exited with code \(exitCode)"
        sessions[toolCallId]?.state = .completed(exitCode: exitCode)
    }

    func fail(toolCallId: String, error: String) {
        sessions[toolCallId]?.statusLine = error
        sessions[toolCallId]?.state = .failed(error)
    }

    func cancel(toolCallId: String) {
        sessions[toolCallId]?.statusLine = "Cancelled"
        sessions[toolCallId]?.state = .cancelled
    }

    func session(forToolCallId toolCallId: String) -> TerminalSession? {
        sessions[toolCallId]
    }

    func session(forSessionId sessionId: String) -> TerminalSession? {
        sessions.values.first(where: { $0.id == sessionId })
    }

    func isTerminalToolResult(_ toolCallId: String) -> Bool {
        sessions[toolCallId] != nil
    }

    func openWindow(forToolCallId toolCallId: String) {
        guard let session = sessions[toolCallId] else { return }
        focusedSessionId = session.id
        isWindowPresented = true
    }
}
