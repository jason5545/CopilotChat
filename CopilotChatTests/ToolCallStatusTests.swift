import Testing
@testable import CopilotChat

@Suite("Tool Call Status Tracking")
struct ToolCallStatusTests {

    @MainActor private func makeService() -> CopilotService {
        CopilotService(authManager: AuthManager(), settingsStore: SettingsStore())
    }

    @Test("New conversation clears tool call statuses")
    @MainActor func newConversationClearsStatuses() {
        let service = makeService()
        service.toolCallStatuses["call_1"] = .completed
        service.toolCallStatuses["call_2"] = .failed("error")
        service.newConversation()
        #expect(service.toolCallStatuses.isEmpty)
        #expect(service.messages.isEmpty)
    }

    @Test("New conversation clears messages")
    @MainActor func newConversationClearsMessages() {
        let service = makeService()
        service.messages.append(ChatMessage(role: .user, content: "hi"))
        service.newConversation()
        #expect(service.messages.isEmpty)
    }

    @Test("ToolCallStatus equality")
    func statusEquality() {
        #expect(ToolCallStatus.pending == .pending)
        #expect(ToolCallStatus.executing == .executing)
        #expect(ToolCallStatus.completed == .completed)
        #expect(ToolCallStatus.failed("err") == .failed("err"))
        #expect(ToolCallStatus.failed("a") != .failed("b"))
        #expect(ToolCallStatus.pending != .executing)
    }
}
