import Foundation
import Observation

@Observable
@MainActor
final class ConversationStore {
    var conversations: [Conversation] = []
    var currentConversationId: UUID?
    private(set) var isDemoSession = false

    private let storageDirectory: URL
    private var saveTask: Task<Void, Never>?
    private let iCloudSync = iCloudSyncManager.shared
    private var preDemoCurrentConversationId: UUID?

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
        WorkspaceManager.shared.currentWorkspaceIdentifier
    }

    var currentConversation: Conversation? {
        guard let id = currentConversationId else { return nil }
        return conversations.first { $0.id == id }
    }

    func conversationsForCurrentWorkspace(_ appMode: AppMode) -> [Conversation] {
        guard appMode == .coding else { return conversations }
        let wsId = Self.currentWorkspaceIdentifier
        if let wsId {
            return conversations.filter {
                WorkspaceManager.shared.matchesWorkspaceIdentifiers($0.workspaceIdentifier, wsId)
            }
        }
        return conversations.filter { $0.workspaceIdentifier == nil }
    }

    // MARK: - Create / Switch

    @discardableResult
    func createConversation(workspaceIdentifier: String? = nil) -> UUID {
        let conversation = Conversation(
            workspaceIdentifier: workspaceIdentifier,
            isDemo: isDemoSession
        )
        conversations.insert(conversation, at: 0)
        currentConversationId = conversation.id
        return conversation.id
    }

    /// Save current messages (if any), then switch to another conversation and return its full state.
    func switchToConversation(
        _ id: UUID,
        currentMessages: [ChatMessage],
        currentSummaryId: UUID? = nil,
        currentReasoningEffort: ReasoningEffort? = nil,
        currentWorkspaceIdentifier: String? = nil
    ) -> (messages: [ChatMessage], summaryMessageId: UUID?, reasoningEffort: ReasoningEffort?, providerId: String?, modelId: String?) {
        saveCurrentIfNeeded(
            messages: currentMessages,
            summaryMessageId: currentSummaryId,
            reasoningEffort: currentReasoningEffort,
            workspaceIdentifier: currentWorkspaceIdentifier)
        currentConversationId = id
        let msgs = loadMessages(for: id)
        let conv = conversations.first { $0.id == id }
        return (msgs, conv?.summaryMessageId, conv?.reasoningEffort, conv?.providerId, conv?.modelId)
    }

    /// Save current messages (if any), then start a fresh conversation.
    func startNewConversation(
        currentMessages: [ChatMessage],
        currentSummaryId: UUID? = nil,
        currentReasoningEffort: ReasoningEffort? = nil,
        currentWorkspaceIdentifier: String? = nil
    ) {
        saveCurrentIfNeeded(
            messages: currentMessages,
            summaryMessageId: currentSummaryId,
            reasoningEffort: currentReasoningEffort,
            workspaceIdentifier: currentWorkspaceIdentifier)
        currentConversationId = nil
    }

    func beginDemoSession(with seededConversations: [Conversation]) {
        guard !isDemoSession || conversations.isEmpty else {
            if currentConversationId == nil {
                currentConversationId = conversations.first?.id
            }
            return
        }

        preDemoCurrentConversationId = currentConversationId
        isDemoSession = true

        let sorted = seededConversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { conversation in
                var demoConversation = conversation
                demoConversation.isDemo = true
                return demoConversation
            }

        conversations = sorted
        currentConversationId = sorted.first?.id
    }

    func endDemoSession() async {
        guard isDemoSession else { return }

        isDemoSession = false
        let restoreId = preDemoCurrentConversationId
        preDemoCurrentConversationId = nil

        await loadAllConversations()

        if let restoreId,
           conversations.contains(where: { $0.id == restoreId }) {
            currentConversationId = restoreId
        } else {
            currentConversationId = conversations.first?.id
        }
    }

    func currentConversationState() -> (messages: [ChatMessage], summaryMessageId: UUID?, reasoningEffort: ReasoningEffort?, providerId: String?, modelId: String?)? {
        guard let currentConversation else { return nil }
        let messages = loadMessages(for: currentConversation.id)
        return (
            messages,
            currentConversation.summaryMessageId,
            currentConversation.reasoningEffort,
            currentConversation.providerId,
            currentConversation.modelId
        )
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
            guard !conv.isDemo else { return }
            await self.saveToDisk(conv)
        }
    }

    /// Save immediately (e.g., before switching conversations).
    private func saveCurrentIfNeeded(
        messages: [ChatMessage],
        summaryMessageId: UUID? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        workspaceIdentifier: String? = nil
    ) {
        guard !messages.isEmpty else { return }
        saveTask?.cancel()
        applyMessagesToCurrentConversation(
            messages,
            summaryMessageId: summaryMessageId,
            reasoningEffort: reasoningEffort,
            workspaceIdentifier: workspaceIdentifier)
        if let id = currentConversationId,
           let conv = conversations.first(where: { $0.id == id }) {
            guard !conv.isDemo else { return }
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
                                         workspaceIdentifier: workspaceIdentifier, isDemo: isDemoSession)
                if let autoTitle, !autoTitle.isEmpty {
                    conv.setTitle(autoTitle)
                } else {
                    conv.generateTitle()
                }
                conversations.insert(conv, at: 0)
                currentConversationId = conv.id
                if !conv.isDemo {
                    Task { await self.saveToDisk(conv) }
                }
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
        guard !conv.isDemo else { return }
        Task { await saveToDisk(conv) }
    }

    func reassignWorkspaceIdentifier(from oldIdentifier: String, to newIdentifier: String) {
        var updatedConversations: [Conversation] = []
        for index in conversations.indices {
            guard WorkspaceManager.shared.matchesWorkspaceIdentifiers(
                conversations[index].workspaceIdentifier,
                oldIdentifier
            ) else {
                continue
            }
            conversations[index].workspaceIdentifier = newIdentifier
            updatedConversations.append(conversations[index])
        }

        for conversation in updatedConversations {
            guard !conversation.isDemo else { continue }
            Task { await saveToDisk(conversation) }
        }
    }

    func deleteProjectConversations(matching workspaceIdentifier: String) {
        let idsToDelete = conversations
            .filter { WorkspaceManager.shared.matchesWorkspaceIdentifiers($0.workspaceIdentifier, workspaceIdentifier) }
            .map(\ .id)

        guard !idsToDelete.isEmpty else { return }

        let deletedConversations = conversations.filter { idsToDelete.contains($0.id) }

        let deletedCurrentConversation = idsToDelete.contains(currentConversationId ?? UUID())
        conversations.removeAll { idsToDelete.contains($0.id) }
        if deletedCurrentConversation {
            currentConversationId = nil
        }

        for conversation in deletedConversations where !conversation.isDemo {
            let url = fileURL(for: conversation.id)
            Task.detached { try? FileManager.default.removeItem(at: url) }
            Task { await iCloudSync.deleteFromCloud(id: conversation.id) }
        }
    }

    // MARK: - Delete

    func deleteConversation(_ id: UUID) {
        let deletedConversation = conversations.first { $0.id == id }
        conversations.removeAll { $0.id == id }
        if currentConversationId == id {
            currentConversationId = nil
        }
        guard deletedConversation?.isDemo != true else { return }
        let url = fileURL(for: id)
        Task.detached { try? FileManager.default.removeItem(at: url) }
        Task { await iCloudSync.deleteFromCloud(id: id) }
    }

    func deleteAllConversations() {
        if isDemoSession {
            conversations.removeAll()
            currentConversationId = nil
            return
        }

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
        guard !isDemoSession else { return }
        guard iCloudSync.isCloudAvailable else { return }
        await iCloudSync.performInitialSync(store: self)
    }

    func handleRemoteUpdate() async {
        guard !isDemoSession else { return }
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
        conversations
            .filter { !$0.isDemo }
            .compactMap { storedConversation(for: $0.id) }
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

        guard !isDemoSession else { return }
        conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }
}
