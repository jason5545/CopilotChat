import Foundation

struct Conversation: Identifiable, Codable {
    static let defaultTitle = "New Conversation"

    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var userMessageCount: Int
    var summaryMessageId: UUID?
    var reasoningEffort: ReasoningEffort?
    var providerId: String?
    var modelId: String?
    var workspaceIdentifier: String?
    var isDemo: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
        messages: [ChatMessage] = [],
        summaryMessageId: UUID? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        workspaceIdentifier: String? = nil,
        isDemo: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.userMessageCount = messages.filter { $0.role == .user }.count
        self.summaryMessageId = summaryMessageId
        self.reasoningEffort = reasoningEffort
        self.providerId = providerId
        self.modelId = modelId
        self.workspaceIdentifier = workspaceIdentifier
        self.isDemo = isDemo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case messages
        case userMessageCount
        case summaryMessageId
        case reasoningEffort
        case providerId
        case modelId
        case workspaceIdentifier
        case isDemo
        case createdAt
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMessages = try container.decode([ChatMessage].self, forKey: .messages)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = decodedMessages
        userMessageCount = try container.decodeIfPresent(Int.self, forKey: .userMessageCount)
            ?? decodedMessages.filter { $0.role == .user }.count
        summaryMessageId = try container.decodeIfPresent(UUID.self, forKey: .summaryMessageId)
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        workspaceIdentifier = try container.decodeIfPresent(String.self, forKey: .workspaceIdentifier)
        isDemo = try container.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Fallback title from first user message. Prefer LLM-generated title via `setTitle(_:)`.
    mutating func generateTitle() {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else { return }
        let text = firstUserMessage.content
        title = text.count > 50 ? String(text.prefix(50)) + "..." : text
    }

    /// Set an LLM-generated title.
    mutating func setTitle(_ newTitle: String) {
        guard !newTitle.isEmpty else { return }
        title = newTitle
    }
}
