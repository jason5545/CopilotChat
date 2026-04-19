import Foundation
import Testing
@testable import CopilotChat

@Suite("Conversation")
struct ConversationTests {

    @Test("Legacy conversation JSON defaults isDemo to false")
    func legacyConversationJSONDefaultsDemoFlag() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Legacy",
          "messages": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "role": "user",
              "content": "hi",
              "timestamp": "2026-04-19T08:00:00Z"
            }
          ],
          "createdAt": "2026-04-19T08:00:00Z",
          "updatedAt": "2026-04-19T08:00:00Z"
        }
        """.data(using: .utf8)!

        let conversation = try ConversationStore.makeDecoder().decode(Conversation.self, from: json)

        #expect(conversation.isDemo == false)
        #expect(conversation.userMessageCount == 1)
    }

    @Test("Conversation encoding preserves demo flag")
    func conversationEncodingPreservesDemoFlag() throws {
        let conversation = Conversation(
            title: "Demo",
            messages: [ChatMessage(role: .assistant, content: "hello")],
            isDemo: true
        )

        let data = try ConversationStore.makeEncoder().encode(conversation)
        let decoded = try ConversationStore.makeDecoder().decode(Conversation.self, from: data)

        #expect(decoded.isDemo == true)
    }
}
