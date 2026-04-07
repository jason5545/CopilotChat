import Testing
import Foundation
@testable import CopilotChat

@Suite("APIMessage Encoding")
struct APIMessageEncodingTests {

    private func encode(_ msg: APIMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(msg)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test("content: null is explicitly present when content is nil")
    func contentNullExplicit() throws {
        let msg = APIMessage(role: "assistant", content: nil)
        let json = try encode(msg)
        #expect(json["content"] is NSNull)
        #expect(json["role"] as? String == "assistant")
    }

    @Test("content is present when set")
    func contentPresent() throws {
        let msg = APIMessage(role: "user", content: "Hello")
        let json = try encode(msg)
        #expect(json["content"] as? String == "Hello")
    }

    @Test("tool_calls is omitted when nil")
    func toolCallsOmitted() throws {
        let msg = APIMessage(role: "assistant", content: nil)
        let json = try encode(msg)
        #expect(json["tool_calls"] == nil)
    }

    @Test("tool_call_id is omitted when nil")
    func toolCallIdOmitted() throws {
        let msg = APIMessage(role: "assistant", content: "hi")
        let json = try encode(msg)
        #expect(json["tool_call_id"] == nil)
    }

    @Test("tool_calls is present when set")
    func toolCallsPresent() throws {
        let tc = APIToolCall(id: "c1", type: "function", function: .init(name: "test", arguments: "{}"))
        let msg = APIMessage(role: "assistant", content: nil, toolCalls: [tc])
        let json = try encode(msg)
        #expect(json["tool_calls"] != nil)
        let calls = json["tool_calls"] as? [[String: Any]]
        #expect(calls?.count == 1)
    }

    @Test("tool_call_id is present when set")
    func toolCallIdPresent() throws {
        let msg = APIMessage(role: "tool", content: "result", toolCallId: "call_1")
        let json = try encode(msg)
        #expect(json["tool_call_id"] as? String == "call_1")
    }

    @Test("Assistant with tool_calls encodes content as null, not missing")
    func assistantToolCallContentNull() throws {
        let tc = APIToolCall(id: "c1", type: "function", function: .init(name: "fn", arguments: "{}"))
        let msg = APIMessage(role: "assistant", content: nil, toolCalls: [tc])
        let data = try JSONEncoder().encode(msg)
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(jsonString.contains("\"content\":null"))
    }
}
