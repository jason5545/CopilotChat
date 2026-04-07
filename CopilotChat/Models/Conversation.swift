import Foundation

struct Conversation: Identifiable, Codable {
    static let defaultTitle = "New Conversation"

    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var userMessageCount: Int
    var summaryMessageId: UUID?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
        messages: [ChatMessage] = [],
        summaryMessageId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.userMessageCount = messages.filter { $0.role == .user }.count
        self.summaryMessageId = summaryMessageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    mutating func generateTitle() {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else { return }
        let text = firstUserMessage.content
        title = text.count > 50 ? String(text.prefix(50)) + "..." : text
    }
}
