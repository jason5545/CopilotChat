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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
