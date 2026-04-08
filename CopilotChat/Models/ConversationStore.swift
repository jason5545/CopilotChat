import Foundation
import Observation

@Observable
@MainActor
final class ConversationStore {
    var conversations: [Conversation] = []
    var currentConversationId: UUID?

    private let storageDirectory: URL
    private var saveTask: Task<Void, Never>?

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageDirectory = documentsPath.appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadAllConversations()
    }

    // MARK: - Current Conversation

    var currentConversation: Conversation? {
        guard let id = currentConversationId else { return nil }
        return conversations.first { $0.id == id }
    }

    // MARK: - Create / Switch

    @discardableResult
    func createConversation() -> UUID {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        currentConversationId = conversation.id
        return conversation.id
    }

    /// Save current messages (if any), then switch to another conversation and return its full state.
    func switchToConversation(_ id: UUID, currentMessages: [ChatMessage], currentSummaryId: UUID? = nil, currentReasoningEffort: ReasoningEffort? = nil) -> (messages: [ChatMessage], summaryMessageId: UUID?, reasoningEffort: ReasoningEffort?) {
        saveCurrentIfNeeded(messages: currentMessages, summaryMessageId: currentSummaryId, reasoningEffort: currentReasoningEffort)
        currentConversationId = id
        let msgs = loadMessages(for: id)
        let conv = conversations.first { $0.id == id }
        return (msgs, conv?.summaryMessageId, conv?.reasoningEffort)
    }

    /// Save current messages (if any), then start a fresh conversation.
    func startNewConversation(currentMessages: [ChatMessage], currentSummaryId: UUID? = nil, currentReasoningEffort: ReasoningEffort? = nil) {
        saveCurrentIfNeeded(messages: currentMessages, summaryMessageId: currentSummaryId, reasoningEffort: currentReasoningEffort)
        currentConversationId = nil
    }

    // MARK: - Update

    /// Schedule a debounced save of the current conversation's messages.
    func updateCurrentConversation(messages: [ChatMessage], summaryMessageId: UUID? = nil, reasoningEffort: ReasoningEffort? = nil) {
        applyMessagesToCurrentConversation(messages, summaryMessageId: summaryMessageId, reasoningEffort: reasoningEffort)

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let id = self.currentConversationId,
                  let conv = self.conversations.first(where: { $0.id == id }) else { return }
            await self.saveToDisk(conv)
        }
    }

    /// Save immediately (e.g., before switching conversations).
    private func saveCurrentIfNeeded(messages: [ChatMessage], summaryMessageId: UUID? = nil, reasoningEffort: ReasoningEffort? = nil) {
        guard !messages.isEmpty else { return }
        saveTask?.cancel()
        applyMessagesToCurrentConversation(messages, summaryMessageId: summaryMessageId, reasoningEffort: reasoningEffort)
        if let id = currentConversationId,
           let conv = conversations.first(where: { $0.id == id }) {
            Task { await self.saveToDisk(conv) }
        }
    }

    private func applyMessagesToCurrentConversation(_ messages: [ChatMessage], summaryMessageId: UUID? = nil, reasoningEffort: ReasoningEffort? = nil) {
        guard let id = currentConversationId,
              let index = conversations.firstIndex(where: { $0.id == id }) else {
            if !messages.isEmpty {
                var conv = Conversation(messages: messages, summaryMessageId: summaryMessageId, reasoningEffort: reasoningEffort)
                conv.generateTitle()
                conversations.insert(conv, at: 0)
                currentConversationId = conv.id
                Task { await self.saveToDisk(conv) }
            }
            return
        }

        conversations[index].messages = messages
        conversations[index].userMessageCount = messages.filter { $0.role == .user }.count
        conversations[index].summaryMessageId = summaryMessageId
        if conversations[index].reasoningEffort != reasoningEffort {
            conversations[index].reasoningEffort = reasoningEffort
        }
        conversations[index].updatedAt = Date()

        if conversations[index].title == Conversation.defaultTitle {
            conversations[index].generateTitle()
        }

        if index != 0 {
            let conv = conversations.remove(at: index)
            conversations.insert(conv, at: 0)
        }
    }

    // MARK: - Rename

    func renameConversation(_ id: UUID, to newTitle: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = newTitle
        conversations[index].updatedAt = Date()
        let conv = conversations[index]
        Task { await saveToDisk(conv) }
    }

    // MARK: - Delete

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentConversationId == id {
            currentConversationId = nil
        }
        let url = fileURL(for: id)
        Task.detached { try? FileManager.default.removeItem(at: url) }
    }

    func deleteAllConversations() {
        let dir = storageDirectory
        conversations.removeAll()
        currentConversationId = nil
        Task.detached {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Persistence

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private nonisolated func saveToDisk(_ conversation: Conversation) async {
        let url = await fileURL(for: conversation.id)
        do {
            let data = try Self.makeEncoder().encode(conversation)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-critical
        }
    }

    private func loadMessages(for id: UUID) -> [ChatMessage] {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let conv = try? Self.makeDecoder().decode(Conversation.self, from: data) else {
            return conversations.first { $0.id == id }?.messages ?? []
        }
        // Update in-memory with full messages
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].messages = conv.messages
        }
        return conv.messages
    }

    private func loadAllConversations() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        var loaded: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conv = try? Self.makeDecoder().decode(Conversation.self, from: data) else {
                continue
            }
            // Store metadata only — clear messages to save memory
            var meta = conv
            meta.messages = []
            loaded.append(meta)
        }

        conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }
}
