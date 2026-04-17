import Testing
import Foundation
@testable import CopilotChat

@Suite("ChatModels")
struct ChatModelsTests {

    private func encodeJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - ChatMessage

    @Test("ChatMessage equality is based on id and content")
    func messageEquality() {
        let id = UUID()
        let m1 = ChatMessage(id: id, role: .user, content: "hi")
        let m2 = ChatMessage(id: id, role: .user, content: "hi")
        let m3 = ChatMessage(id: id, role: .user, content: "bye")
        #expect(m1 == m2)
        #expect(m1 != m3)
    }

    @Test("ChatMessage defaults")
    func messageDefaults() {
        let msg = ChatMessage(role: .assistant, content: "test")
        #expect(msg.toolCalls == nil)
        #expect(msg.toolCallId == nil)
        #expect(msg.toolName == nil)
    }

    // MARK: - ToolCall

    @Test("ToolCall is Codable")
    func toolCallCodable() throws {
        let call = ToolCall(id: "tc_1", function: .init(name: "search", arguments: "{\"q\":\"test\"}"))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        #expect(decoded.id == "tc_1")
        #expect(decoded.function.name == "search")
        #expect(decoded.function.arguments == "{\"q\":\"test\"}")
    }

    // MARK: - StreamChunk Decoding

    @Test("Decodes content delta chunk")
    func decodeContentDelta() throws {
        let json = """
        {"id":"id","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        """
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: json.data(using: .utf8)!)
        #expect(chunk.choices?.first?.delta.content == "Hello")
        #expect(chunk.choices?.first?.finishReason == nil)
    }

    @Test("Decodes finish reason chunk")
    func decodeFinishReason() throws {
        let json = """
        {"id":"id","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: json.data(using: .utf8)!)
        #expect(chunk.choices?.first?.finishReason == "stop")
    }

    @Test("Decodes tool_calls finish reason")
    func decodeToolCallsFinish() throws {
        let json = """
        {"id":"id","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}]}
        """
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: json.data(using: .utf8)!)
        #expect(chunk.choices?.first?.finishReason == "tool_calls")
        #expect(chunk.choices?.first?.delta.toolCalls?.count == 1)
    }

    @Test("Decodes tool call delta with id and name")
    func decodeToolCallDelta() throws {
        let json = """
        {"id":"id","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":""}}]},"finish_reason":null}]}
        """
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: json.data(using: .utf8)!)
        let tc = chunk.choices?.first?.delta.toolCalls?.first
        #expect(tc?.index == 0)
        #expect(tc?.id == "call_1")
        #expect(tc?.function?.name == "search")
    }

    // MARK: - AnyCodable

    @Test("AnyCodable roundtrips basic types")
    func anyCodableRoundtrip() throws {
        let values: [AnyCodable] = [
            AnyCodable("string"),
            AnyCodable(42),
            AnyCodable(3.14),
            AnyCodable(true),
        ]
        for val in values {
            let data = try JSONEncoder().encode(val)
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
            #expect(String(describing: decoded.value) == String(describing: val.value))
        }
    }

    @Test("AnyCodable handles nested dict")
    func anyCodableDict() throws {
        let val = AnyCodable(["key": "value", "num": 42] as [String: Any])
        let data = try JSONEncoder().encode(val)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.value as? [String: Any]
        #expect(dict?["key"] as? String == "value")
    }

    @Test("ResponsesAPIRequest encodes store when explicitly set")
    func responsesRequestEncodesStore() throws {
        let request = ResponsesAPIRequest(
            model: "gpt-5.3-codex",
            instructions: "test",
            input: [.userMessage(content: "hello")],
            stream: true,
            store: false,
            maxOutputTokens: 256,
            temperature: 0.2,
            tools: nil,
            toolChoice: nil,
            reasoning: nil
        )

        let json = try encodeJSON(request)
        #expect(json["store"] as? Bool == false)
    }

    @Test("ResponsesAPIRequest omits store when unset")
    func responsesRequestOmitsStoreWhenUnset() throws {
        let request = ResponsesAPIRequest(
            model: "gpt-5.3-codex",
            instructions: nil,
            input: [.userMessage(content: "hello")],
            stream: false,
            maxOutputTokens: nil,
            temperature: nil,
            tools: nil,
            toolChoice: nil,
            reasoning: nil
        )

        let json = try encodeJSON(request)
        #expect(json["store"] == nil)
    }

    @Test("OpenAI Codex request omits max_output_tokens for ChatGPT backend")
    func openAICodexRequestOmitsMaxOutputTokens() throws {
        let request = OpenAICodexProvider.buildResponsesRequest(
            model: "gpt-5.4",
            input: [.userMessage(content: "hello")],
            tools: nil,
            options: ProviderOptions(
                maxOutputTokens: 4096,
                temperature: 0.2,
                reasoningEffort: "high",
                systemPrompt: "test"
            ),
            stream: true
        )

        let json = try encodeJSON(request)
        #expect(json["max_output_tokens"] == nil)
        #expect(json["store"] as? Bool == false)
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == "high")
    }
}
