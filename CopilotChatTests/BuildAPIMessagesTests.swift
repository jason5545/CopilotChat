import Testing
@testable import CopilotChat

@Suite("buildAPIMessages")
struct BuildAPIMessagesTests {

    @MainActor private func makeService() -> (CopilotService, AuthManager) {
        let auth = AuthManager()
        let settings = SettingsStore()
        return (CopilotService(authManager: auth, settingsStore: settings), auth)
    }

    // MARK: - Basic Messages

    @Test("Empty conversation has only system message")
    @MainActor func emptyConversation() {
        let (service, _) = makeService()
        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 1)
        #expect(msgs[0].role == "system")
    }

    @Test("User message is included")
    @MainActor func userMessage() {
        let (service, _) = makeService()
        service.messages.append(ChatMessage(role: .user, content: "Hello"))
        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 2)
        #expect(msgs[1].role == "user")
        #expect(msgs[1].content == "Hello")
    }

    @Test("Assistant message with content is included")
    @MainActor func assistantMessage() {
        let (service, _) = makeService()
        service.messages.append(ChatMessage(role: .user, content: "Hi"))
        service.messages.append(ChatMessage(role: .assistant, content: "Hello!"))
        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 3)
        #expect(msgs[2].role == "assistant")
        #expect(msgs[2].content == "Hello!")
    }

    @Test("Empty assistant message is skipped")
    @MainActor func emptyAssistant() {
        let (service, _) = makeService()
        service.messages.append(ChatMessage(role: .user, content: "Hi"))
        service.messages.append(ChatMessage(role: .assistant, content: ""))
        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 2) // system + user only
    }

    // MARK: - Tool Call Messages

    @Test("Assistant with tool calls + tool result produces valid sequence")
    @MainActor func toolCallSequence() {
        let (service, _) = makeService()
        let toolCall = ToolCall(id: "call_1", function: .init(name: "test", arguments: "{}"))
        service.messages.append(ChatMessage(role: .user, content: "Do something"))
        service.messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [toolCall]))
        service.messages.append(ChatMessage(role: .tool, content: "Result", toolCallId: "call_1", toolName: "test"))

        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 4) // system + user + assistant(tool_calls) + tool
        #expect(msgs[2].role == "assistant")
        #expect(msgs[2].toolCalls?.count == 1)
        #expect(msgs[2].content == nil) // empty content → nil
        #expect(msgs[3].role == "tool")
        #expect(msgs[3].toolCallId == "call_1")
    }

    @Test("Unanswered tool calls are excluded")
    @MainActor func unansweredToolCalls() {
        let (service, _) = makeService()
        let toolCall = ToolCall(id: "call_1", function: .init(name: "test", arguments: "{}"))
        service.messages.append(ChatMessage(role: .user, content: "Do something"))
        service.messages.append(ChatMessage(role: .assistant, content: "thinking...", toolCalls: [toolCall]))
        // No tool result — tool call should be excluded

        let msgs = service.buildAPIMessages()
        // assistant has content "thinking..." so it becomes a plain text message
        #expect(msgs.count == 3) // system + user + assistant(plain text)
        #expect(msgs[2].role == "assistant")
        #expect(msgs[2].toolCalls == nil) // tool calls stripped
        #expect(msgs[2].content == "thinking...")
    }

    @Test("Unanswered tool calls with empty content are fully skipped")
    @MainActor func unansweredToolCallsNoContent() {
        let (service, _) = makeService()
        let toolCall = ToolCall(id: "call_1", function: .init(name: "test", arguments: "{}"))
        service.messages.append(ChatMessage(role: .user, content: "Do something"))
        service.messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [toolCall]))
        // No tool result, no content → entire message is skipped

        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 2) // system + user only
    }

    @Test("Multiple tool calls — only answered ones are included")
    @MainActor func partialToolCallAnswers() {
        let (service, _) = makeService()
        let call1 = ToolCall(id: "call_1", function: .init(name: "test1", arguments: "{}"))
        let call2 = ToolCall(id: "call_2", function: .init(name: "test2", arguments: "{}"))
        service.messages.append(ChatMessage(role: .user, content: "Do things"))
        service.messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [call1, call2]))
        service.messages.append(ChatMessage(role: .tool, content: "Result 1", toolCallId: "call_1", toolName: "test1"))
        // call_2 has no result

        let msgs = service.buildAPIMessages()
        let assistantMsg = msgs.first(where: { $0.role == "assistant" && $0.toolCalls != nil })!
        #expect(assistantMsg.toolCalls?.count == 1)
        #expect(assistantMsg.toolCalls?[0].id == "call_1")
    }

    // MARK: - Tool Call + Follow-up Sequence

    @Test("Full tool call roundtrip produces correct API sequence")
    @MainActor func fullToolCallRoundtrip() {
        let (service, _) = makeService()
        let toolCall = ToolCall(id: "call_1", function: .init(name: "search", arguments: "{\"q\":\"test\"}"))

        service.messages.append(ChatMessage(role: .user, content: "Search for test"))
        service.messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [toolCall]))
        service.messages.append(ChatMessage(role: .tool, content: "Found 5 results", toolCallId: "call_1", toolName: "search"))
        service.messages.append(ChatMessage(role: .assistant, content: "I found 5 results for your search."))

        let msgs = service.buildAPIMessages()
        #expect(msgs.count == 5) // system + user + assistant(tool_calls) + tool + assistant(text)
        #expect(msgs[1].role == "user")
        #expect(msgs[2].role == "assistant")
        #expect(msgs[2].toolCalls != nil)
        #expect(msgs[3].role == "tool")
        #expect(msgs[4].role == "assistant")
        #expect(msgs[4].content == "I found 5 results for your search.")
    }
}
