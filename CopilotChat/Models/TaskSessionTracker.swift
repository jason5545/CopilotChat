import Foundation
import SwiftUI

enum TaskAgentState: Equatable {
    case running
    case completed
    case failed(String)
    case cancelled
}

@Observable
@MainActor
final class TaskSessionTracker {
    static let shared = TaskSessionTracker()

    private(set) var sessions: [String: TaskSession] = [:]

    struct TaskSession: Identifiable {
        let id: String
        let toolCallId: String
        let agentType: String
        let description: String
        var state: TaskAgentState
        var messages: [ChatMessage]
        var resultContent: String
        var iterations: Int
        var lastUpdated: Date

        init(id: String, toolCallId: String, agentType: String, description: String) {
            self.id = id
            self.toolCallId = toolCallId
            self.agentType = agentType
            self.description = description
            self.state = .running
            self.messages = []
            self.resultContent = ""
            self.iterations = 0
            self.lastUpdated = Date()
        }
    }

    private init() {}

    func startSession(id: String, toolCallId: String, agentType: String, description: String) {
        sessions[toolCallId] = TaskSession(
            id: id,
            toolCallId: toolCallId,
            agentType: agentType,
            description: description
        )
    }

    func appendMessage(_ message: ChatMessage, forToolCallId toolCallId: String) {
        sessions[toolCallId]?.messages.append(message)
        sessions[toolCallId]?.lastUpdated = Date()
    }

    func updateResult(_ content: String, forToolCallId toolCallId: String) {
        sessions[toolCallId]?.resultContent = content
        sessions[toolCallId]?.lastUpdated = Date()
    }

    func complete(toolCallId: String, result: String, messages: [ChatMessage]) {
        sessions[toolCallId]?.state = .completed
        sessions[toolCallId]?.resultContent = result
        sessions[toolCallId]?.messages = messages
        sessions[toolCallId]?.lastUpdated = Date()
    }

    func fail(toolCallId: String, error: String) {
        sessions[toolCallId]?.state = .failed(error)
        sessions[toolCallId]?.lastUpdated = Date()
    }

    func cancel(toolCallId: String) {
        sessions[toolCallId]?.state = .cancelled
        sessions[toolCallId]?.lastUpdated = Date()
    }

    func incrementIterations(forToolCallId toolCallId: String) {
        sessions[toolCallId]?.iterations += 1
        sessions[toolCallId]?.lastUpdated = Date()
    }

    func session(forToolCallId toolCallId: String) -> TaskSession? {
        sessions[toolCallId]
    }

    func removeSession(forToolCallId toolCallId: String) {
        sessions.removeValue(forKey: toolCallId)
    }

    func isTaskToolResult(_ toolCallId: String) -> Bool {
        sessions[toolCallId] != nil
    }

    func completeSessionWithResult(toolCallId: String, result: String) {
        if let taskId = parseTaskId(from: result) {
            if var session = sessions[toolCallId] {
                session.state = .completed
                session.resultContent = extractResultContent(from: result)
                session.messages = []
                sessions[taskId] = session
            }
        }
    }

    private func parseTaskId(from text: String) -> String? {
        let pattern = "task_id: ([a-zA-Z0-9_]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func extractResultContent(from text: String) -> String {
        let pattern = "<task_result>([\\s\\S]*?)</task_result>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return text
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
