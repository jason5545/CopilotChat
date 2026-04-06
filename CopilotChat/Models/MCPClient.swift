import Foundation

actor MCPClient {
    private let config: MCPServerConfig
    private var sessionId: String?
    private var nextRequestId = 1

    var tools: [MCPTool] = []
    var isConnected = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - Connection

    func connect() async throws {
        try await initialize()
        try await listTools()
        isConnected = true
    }

    func disconnect() {
        sessionId = nil
        tools = []
        isConnected = false
    }

    // MARK: - JSON-RPC Requests

    private func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2025-03-26",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": "CopilotChat",
                "version": "1.0.0",
            ] as [String: String],
        ]

        let response = try await sendRequest(method: "initialize", params: params)

        // Send initialized notification
        try await sendNotification(method: "notifications/initialized")

        // Check for session ID in response headers (stored during sendRequest)
        if let result = response["result"] as? [String: Any],
           let _ = result["protocolVersion"] as? String {
            // Successfully initialized
        }
    }

    private func listTools() async throws {
        let response = try await sendRequest(method: "tools/list", params: nil)

        guard let result = response["result"] as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]] else {
            return
        }

        tools = toolsArray.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let description = dict["description"] as? String ?? ""
            var inputSchema: [String: AnyCodable]?
            if let schema = dict["inputSchema"] as? [String: Any] {
                inputSchema = schema.mapValues { AnyCodable($0) }
            }
            return MCPTool(name: name, description: description, inputSchema: inputSchema, serverName: config.name)
        }
    }

    func callTool(name: String, argumentsJSON: String) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments,
        ]

        let response = try await sendRequest(method: "tools/call", params: params)

        guard let result = response["result"] as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        // Extract content from result
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                if item["type"] as? String == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            return texts.joined(separator: "\n")
        }

        // Fallback: serialize result as JSON
        let data = try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
        return String(data: data, encoding: .utf8) ?? "No result"
    }

    // MARK: - HTTP Transport

    private func sendRequest(method: String, params: Any?) async throws -> [String: Any] {
        let id = nextRequestId
        nextRequestId += 1

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            body["params"] = params
        }

        let (data, httpResponse) = try await performHTTPRequest(body: body)

        // Store session ID from response
        if let http = httpResponse as? HTTPURLResponse,
           let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = sid
        }

        // Check content type for SSE vs JSON
        if let http = httpResponse as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.contains("text/event-stream") {
            return try parseSSEResponse(data: data, expectedId: id)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }
        return json
    }

    private func sendNotification(method: String) async throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        _ = try await performHTTPRequest(body: body)
    }

    private func performHTTPRequest(body: [String: Any]) async throws -> (Data, URLResponse) {
        guard let url = URL(string: config.url) else {
            throw MCPError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        if let sid = sessionId {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }

        // Add custom headers from config
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request)
    }

    private func parseSSEResponse(data: Data, expectedId: Int) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.invalidResponse
        }

        // Parse SSE lines to find the JSON-RPC response matching our ID
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let id = json["id"] as? Int, id == expectedId else { continue }
            return json
        }

        throw MCPError.invalidResponse
    }

    // MARK: - Errors

    enum MCPError: LocalizedError {
        case invalidURL
        case invalidResponse
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid MCP server URL"
            case .invalidResponse: "Invalid response from MCP server"
            case .serverError(let msg): "MCP server error: \(msg)"
            }
        }
    }
}
