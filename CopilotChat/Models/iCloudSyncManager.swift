import Foundation
import Observation

@Observable
@MainActor
final class iCloudSyncManager {
    static let shared = iCloudSyncManager()

    var isCloudAvailable = false
    var syncStatus: SyncStatus = .idle

    enum SyncStatus {
        case idle
        case syncing
        case synced
        case failed(Error?)
    }

    private let ubiquityContainerIdentifier = "iCloud.com.copilotchat.app"
    private let conversationsSubdirectory = "Conversations"
    private let metadataFilename = "metadata.json"

    private var metadataQuery: NSMetadataQuery?
    private var fileCoordinator: NSFileCoordinator?

    private init() {
        checkCloudAvailability()
    }

    // MARK: - Cloud Availability

    private func checkCloudAvailability() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = FileManager.default.url(forUbiquityContainerIdentifier: self?.ubiquityContainerIdentifier)
            DispatchQueue.main.async {
                self?.isCloudAvailable = url != nil
                if url != nil {
                    self?.startMetadataQuery()
                }
            }
        }
    }

    // MARK: - Ubiquity Container URL

    var cloudDirectory: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerIdentifier)
    }

    var conversationsDirectory: URL? {
        cloudDirectory?.appendingPathComponent(conversationsSubdirectory, isDirectory: true)
    }

    // MARK: - Metadata Query (remote change monitoring)

    private func startMetadataQuery() {
        guard metadataQuery == nil else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K LIKE '%@.*'",
                                       NSMetadataItemFSNameKey, conversationsSubdirectory)
        query.notificationBatchingInterval = 1

        NotificationCenter.default.addObserver(self,
            selector: #selector(metadataQueryDidUpdate),
            name: NSNotification.Name.NSMetadataQueryDidUpdate,
            object: query)
        NotificationCenter.default.addObserver(self,
            selector: #selector(metadataQueryDidFinishGathering),
            name: NSNotification.Name.NSMetadataQueryDidFinishGathering,
            object: query)

        query.start()
        metadataQuery = query
    }

    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        handleMetadataResults()
    }

    @objc private func metadataQueryDidFinishGathering(_ notification: Notification) {
        handleMetadataResults()
    }

    private func handleMetadataResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()

        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                guard let fileName = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                      fileName.hasSuffix(".json") else { continue }
            }
        }

        query.enableUpdates()
    }

    // MARK: - Upload

    func uploadConversation(_ conversation: Conversation) async {
        guard let cloudDir = conversationsDirectory else { return }
        syncStatus = .syncing

        do {
            try await ensureDirectoryExists(at: cloudDir)
            let filename = "\(conversation.id.uuidString).json"
            let cloudURL = cloudDir.appendingPathComponent(filename)
            let localURL = localURL(for: conversation.id)

            let data = try ConversationStore.makeEncoder().encode(conversation)

            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var writeError: Error?

            coordinator.coordinate(writingItemAt: cloudURL, options: .forReplacing, error: &coordError) { newURL in
                do {
                    try data.write(to: newURL, options: .atomic)
                } catch {
                    writeError = error
                }
            }

            if let coordError {
                throw coordError
            }
            if let writeError {
                throw writeError
            }

            syncStatus = .synced
        } catch {
            syncStatus = .failed(error)
        }
    }

    func deleteFromCloud(id: UUID) async {
        guard let cloudDir = conversationsDirectory else { return }
        let filename = "\(id.uuidString).json"
        let cloudURL = cloudDir.appendingPathComponent(filename)

        let coordinator = NSFileCoordinator()
        var coordError: NSError?

        coordinator.coordinate(writingItemAt: cloudURL, options: .forDeleting, error: &coordError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Download / Merge

    func downloadRemoteConversations() async -> [Conversation] {
        guard let cloudDir = conversationsDirectory else { return [] }
        syncStatus = .syncing

        do {
            let files = try FileManager.default.contentsOfDirectory(at: cloudDir,
                                                                      includingPropertiesForKeys: nil)
            var conversations: [Conversation] = []

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let conv = try? ConversationStore.makeDecoder().decode(Conversation.self, from: data) else {
                    continue
                }
                conversations.append(conv)
            }

            syncStatus = .synced
            return conversations
        } catch {
            syncStatus = .failed(error)
            return []
        }
    }

    /// Merge remote conversations into local store, resolving conflicts by keeping the newer version.
    func mergeRemoteConversations(into store: ConversationStore) async {
        let remoteConversations = await downloadRemoteConversations()

        for remote in remoteConversations {
            if let localIndex = store.conversations.firstIndex(where: { $0.id == remote.id }) {
                let local = store.conversations[localIndex]
                if remote.updatedAt > local.updatedAt {
                    await store.upsertConversationFromSync(remote)
                }
            } else {
                await store.upsertConversationFromSync(remote)
            }
        }

        store.conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Initial Sync

    func performInitialSync(store: ConversationStore) async {
        guard isCloudAvailable else { return }
        await mergeRemoteConversations(into: store)

        for conv in store.storedConversationsForSync() {
            await uploadConversation(conv)
        }
    }

    // MARK: - Helpers

    private func localURL(for id: UUID) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Conversations/\(id.uuidString).json")
    }

    private func ensureDirectoryExists(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Resolve Conflict

    enum ConflictResolution {
        case keepLocal
        case keepRemote
        case merge
    }

    func resolveConflict(local: Conversation, remote: Conversation) -> Conversation {
        if remote.updatedAt > local.updatedAt {
            var merged = remote
            merged.messages = local.messages + remote.messages.filter { msg in
                !local.messages.contains(where: { $0.id == msg.id })
            }
            return merged
        }
        return local
    }
}
