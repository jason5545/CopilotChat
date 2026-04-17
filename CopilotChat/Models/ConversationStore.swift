import Foundation
import Observation

@Observable
@MainActor
final class ConversationStore {
    var conversations: [Conversation] = []
    var currentConversationId: UUID?

    private let storageDirectory: URL
    private var saveTask: Task<Void, Never>?
    private let iCloudSync = iCloudSyncManager.shared

    nonisolated static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageDirectory = documentsPath.appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        Task { await loadAllConversations() }
    }

    // MARK: - Current Conversation

    static var currentWorkspaceIdentifier: String? {
        guard WorkspaceManager.shared.hasWorkspace,
              let url = WorkspaceManager.shared.currentURL else { return nil }
        return url.absoluteString
    }

    var currentConversation: Conversation? {
        guard let id = currentConversationId else { return nil }
        return conversations.first { $0.id == id }
    }

    func conversationsForCurrentWorkspace(_ appMode: AppMode) -> [Conversation] {
        guard appMode == .coding else { return conversations }
        let wsId = Self.currentWorkspaceIdentifier
        if let wsId {
            return conversations.filter { $0.workspaceIdentifier == wsId }
        }
        return conversations.filter { $0.workspaceIdentifier == nil }
    }

    // MARK: - Create / Switch

    @discardableResult
    func createConversation(workspaceIdentifier: String? = nil) -> UUID {
        let conversation = Conversation(workspaceIdentifier: workspaceIdentifier)
        conversations.insert(conversation, at: 0)
        currentConversationId = conversation.id
        return conversation.id
    }

    /// Save current messages (if any), then switch to another conversation and return its full state.
    func switchToConversation(
        _ id: UUID,
        currentMessages: [ChatMessage],
        currentSummaryId: UUID? = nil,
        currentReasoningEffort: ReasoningEffort? = nil
    ) -> (messages: [ChatMessage], summaryMessageId: UUID?, reasoningEffort: ReasoningEffort?, providerId: String?, modelId: String?) {
        saveCurrentIfNeeded(
            messages: currentMessages,
            summaryMessageId: currentSummaryId,
            reasoningEffort: currentReasoningEffort)
        currentConversationId = id
        let msgs = loadMessages(for: id)
        let conv = conversations.first { $0.id == id }
        return (msgs, conv?.summaryMessageId, conv?.reasoningEffort, conv?.providerId, conv?.modelId)
    }

    /// Save current messages (if any), then start a fresh conversation.
    func startNewConversation(
        currentMessages: [ChatMessage],
        currentSummaryId: UUID? = nil,
        currentReasoningEffort: ReasoningEffort? = nil
    ) {
        saveCurrentIfNeeded(
            messages: currentMessages,
            summaryMessageId: currentSummaryId,
            reasoningEffort: currentReasoningEffort)
        currentConversationId = nil
    }

    // MARK: - Update

    /// Schedule a debounced save of the current conversation's messages.
    func updateCurrentConversation(
        messages: [ChatMessage],
        summaryMessageId: UUID? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        autoTitle: String? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        workspaceIdentifier: String? = nil
    ) {
        applyMessagesToCurrentConversation(
            messages, summaryMessageId: summaryMessageId, reasoningEffort: reasoningEffort,
            autoTitle: autoTitle, providerId: providerId, modelId: modelId,
            workspaceIdentifier: workspaceIdentifier)

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
    private func saveCurrentIfNeeded(
        messages: [ChatMessage],
        summaryMessageId: UUID? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        guard !messages.isEmpty else { return }
        saveTask?.cancel()
        applyMessagesToCurrentConversation(
            messages,
            summaryMessageId: summaryMessageId,
            reasoningEffort: reasoningEffort)
        if let id = currentConversationId,
           let conv = conversations.first(where: { $0.id == id }) {
            Task { await self.saveToDisk(conv) }
        }
    }

    private func applyMessagesToCurrentConversation(
        _ messages: [ChatMessage],
        summaryMessageId: UUID? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        autoTitle: String? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        workspaceIdentifier: String? = nil
    ) {
        guard let id = currentConversationId,
              let index = conversations.firstIndex(where: { $0.id == id }) else {
            if !messages.isEmpty {
                var conv = Conversation(messages: messages, summaryMessageId: summaryMessageId,
                                         reasoningEffort: reasoningEffort, providerId: providerId, modelId: modelId,
                                         workspaceIdentifier: workspaceIdentifier)
                if let autoTitle, !autoTitle.isEmpty {
                    conv.setTitle(autoTitle)
                } else {
                    conv.generateTitle()
                }
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
        if let providerId { conversations[index].providerId = providerId }
        if let modelId { conversations[index].modelId = modelId }
        if conversations[index].workspaceIdentifier == nil, let workspaceIdentifier {
            conversations[index].workspaceIdentifier = workspaceIdentifier
        }
        conversations[index].updatedAt = Date()

        // Use LLM-generated title if available, otherwise fallback to truncation
        if conversations[index].title == Conversation.defaultTitle {
            if let autoTitle, !autoTitle.isEmpty {
                conversations[index].setTitle(autoTitle)
            } else {
                conversations[index].generateTitle()
            }
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
        Task { await iCloudSync.deleteFromCloud(id: id) }
    }

    func deleteAllConversations() {
        let dir = storageDirectory
        conversations.removeAll()
        currentConversationId = nil
        Task.detached {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Remote cleanup handled lazily; local state is cleared immediately
    }

    // MARK: - iCloud Sync

    func syncWithCloud() async {
        guard iCloudSync.isCloudAvailable else { return }
        await iCloudSync.performInitialSync(store: self)
    }

    func handleRemoteUpdate() async {
        guard iCloudSync.isCloudAvailable else { return }
        let hadCurrentId = currentConversationId
        await iCloudSync.mergeRemoteConversations(into: self)
        if let hadCurrentId, conversations.contains(where: { $0.id == hadCurrentId }) {
            currentConversationId = hadCurrentId
        }
    }

    // MARK: - Persistence

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    func storedConversation(for id: UUID) -> Conversation? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let conv = try? Self.makeDecoder().decode(Conversation.self, from: data) else {
            return conversations.first { $0.id == id }
        }
        return conv
    }

    func storedConversationsForSync() -> [Conversation] {
        conversations.compactMap { storedConversation(for: $0.id) }
    }

    func upsertConversationFromSync(_ conversation: Conversation) async {
        await writeToDisk(conversation)

        var metadata = conversation
        if metadata.id != currentConversationId {
            metadata.messages = []
        }

        if let index = conversations.firstIndex(where: { $0.id == metadata.id }) {
            conversations[index] = metadata
        } else {
            conversations.append(metadata)
        }
    }

    private nonisolated func writeToDisk(_ conversation: Conversation) async {
        let url = await fileURL(for: conversation.id)
        do {
            let data = try Self.makeEncoder().encode(conversation)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-critical
        }
    }

    private nonisolated func saveToDisk(_ conversation: Conversation) async {
        await writeToDisk(conversation)
        // Sync to iCloud
        await iCloudSync.uploadConversation(conversation)
    }

    private func loadMessages(for id: UUID) -> [ChatMessage] {
        guard let conv = storedConversation(for: id) else {
            return conversations.first { $0.id == id }?.messages ?? []
        }
        // Update in-memory with full messages
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].messages = conv.messages
        }
        return conv.messages
    }

    private func loadAllConversations() async {
        let dir = storageDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []

        var loaded: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conv = try? Self.makeDecoder().decode(Conversation.self, from: data) else {
                continue
            }
            var meta = conv
            meta.messages = []
            loaded.append(meta)
        }

        conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }
}
