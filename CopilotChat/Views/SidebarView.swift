import SwiftUI

struct SidebarView: View {
    @Environment(ConversationStore.self) private var store
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AuthManager.self) private var authManager

    @State private var searchText = ""
    @State private var expandedProjectIDs: Set<String> = []

    private var isCodingMode: Bool {
        settingsStore.appMode == .coding
    }

    private var filteredConversations: [Conversation] {
        let scoped = store.conversationsForCurrentWorkspace(settingsStore.appMode)
        guard !searchText.isEmpty else { return scoped }
        let query = searchText.lowercased()
        return scoped.filter { $0.title.lowercased().contains(query) }
    }

    private var allProjectGroups: [SidebarProjectGroup] {
        buildProjectGroups(query: nil)
    }

    private var filteredProjectGroups: [SidebarProjectGroup] {
        buildProjectGroups(query: searchText)
    }

    var body: some View {
        Group {
            if isCodingMode {
                if filteredProjectGroups.isEmpty {
                    emptyState(
                        title: "No Project Conversations",
                        message: "Start a new project chat to begin."
                    )
                } else {
                    projectTree
                }
            } else if filteredConversations.isEmpty {
                emptyState(
                    title: "No Conversations",
                    message: "Start a new chat to begin."
                )
            } else {
                conversationList
            }
        }
        .background(Color.carbonBlack)
        .onAppear {
            syncExpandedProjectIDs()
        }
        .onChange(of: allProjectGroups.map(\ .id)) { _, _ in
            syncExpandedProjectIDs()
        }
    }

    @ViewBuilder
    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: Carbon.spacingRelaxed) {
            Spacer()
            Image(systemName: isCodingMode ? "folder.badge.gearshape" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.carbonTextTertiary)
            VStack(spacing: Carbon.spacingTight) {
                Text(title)
                    .font(.carbonSerif(.subheadline))
                    .foregroundStyle(Color.carbonTextSecondary)
                Text(message)
                    .font(.carbonSans(.caption))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var projectTree: some View {
        List {
            ForEach(filteredProjectGroups) { group in
                Button {
                    toggleProject(group.id)
                } label: {
                    SidebarProjectRow(group: group, isExpanded: isProjectExpanded(group.id))
                }
                .buttonStyle(.plain)
                .listRowBackground(group.isCurrentWorkspace ? Color.carbonElevated : Color.carbonSurface)

                if isProjectExpanded(group.id) {
                    ForEach(group.conversations) { conversation in
                        Button {
                            resumeConversation(conversation.id)
                        } label: {
                            SidebarConversationRow(
                                conversation: conversation,
                                isCurrent: conversation.id == store.currentConversationId,
                                isNested: true
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            conversation.id == store.currentConversationId
                                ? Color.carbonElevated
                                : Color.carbonSurface
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteConversation(conversation.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search projects and conversations")
    }

    private func buildProjectGroups(query: String?) -> [SidebarProjectGroup] {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let grouped = Dictionary(grouping: store.conversations) { $0.workspaceIdentifier }

        return grouped.compactMap { workspaceIdentifier, conversations in
            let sortedConversations = conversations.sorted { $0.updatedAt > $1.updatedAt }
            let group = SidebarProjectGroup(
                workspaceIdentifier: workspaceIdentifier,
                conversations: sortedConversations,
                currentWorkspaceIdentifier: ConversationStore.currentWorkspaceIdentifier
            )

            guard let normalizedQuery, !normalizedQuery.isEmpty else {
                return group
            }

            let groupMatches = group.searchableText.contains(normalizedQuery)
            if groupMatches {
                return group
            }

            let matchingConversations = sortedConversations.filter {
                $0.title.lowercased().contains(normalizedQuery)
            }
            guard !matchingConversations.isEmpty else { return nil }

            return SidebarProjectGroup(
                workspaceIdentifier: workspaceIdentifier,
                conversations: matchingConversations,
                currentWorkspaceIdentifier: ConversationStore.currentWorkspaceIdentifier
            )
        }
        .sorted { lhs, rhs in
            if lhs.isCurrentWorkspace != rhs.isCurrentWorkspace {
                return lhs.isCurrentWorkspace
            }
            if lhs.isUnassigned != rhs.isUnassigned {
                return !lhs.isUnassigned
            }
            return lhs.latestUpdatedAt > rhs.latestUpdatedAt
        }
    }

    private func isProjectExpanded(_ id: String) -> Bool {
        !searchText.isEmpty || expandedProjectIDs.contains(id)
    }

    private func toggleProject(_ id: String) {
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
    }

    private func syncExpandedProjectIDs() {
        let validIDs = Set(allProjectGroups.map(\ .id))
        expandedProjectIDs = expandedProjectIDs.intersection(validIDs)

        guard expandedProjectIDs.isEmpty else { return }
        if let currentProject = allProjectGroups.first(where: { $0.isCurrentWorkspace }) {
            expandedProjectIDs.insert(currentProject.id)
        } else if let firstProject = allProjectGroups.first {
            expandedProjectIDs.insert(firstProject.id)
        }
    }

    private func resumeConversation(_ id: UUID) {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else { return }
        copilotService.stopStreaming()
        let result = store.switchToConversation(
            conversation.id,
            currentMessages: copilotService.messages,
            currentSummaryId: copilotService.summaryMessageId,
            currentReasoningEffort: settingsStore.reasoningEffort
        )
        copilotService.loadMessages(result.messages, summaryMessageId: result.summaryMessageId)
        if let effort = result.reasoningEffort {
            settingsStore.reasoningEffort = effort
        }
        if let providerId = result.providerId, let registry = copilotService.providerRegistry {
            registry.activeProviderId = providerId
        }
        if let modelId = result.modelId, let registry = copilotService.providerRegistry {
            registry.activeModelId = modelId
        }
    }

    private var conversationList: some View {
        List(selection: Binding(
            get: { store.currentConversationId },
            set: { id in
                if let id {
                    resumeConversation(id)
                }
            }
        )) {
            ForEach(filteredConversations) { conversation in
                SidebarConversationRow(
                    conversation: conversation,
                    isCurrent: conversation.id == store.currentConversationId,
                    isNested: false
                )
                .tag(conversation.id)
                .listRowBackground(
                    conversation.id == store.currentConversationId
                        ? Color.carbonElevated
                        : Color.carbonSurface
                )
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteConversation(conversation.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search")
    }
}

private struct SidebarProjectGroup: Identifiable {
    let workspaceIdentifier: String?
    let title: String
    let subtitle: String?
    let conversations: [Conversation]
    let isCurrentWorkspace: Bool

    var id: String {
        workspaceIdentifier ?? "__unassigned__"
    }

    var latestUpdatedAt: Date {
        conversations.first?.updatedAt ?? .distantPast
    }

    var isUnassigned: Bool {
        workspaceIdentifier == nil
    }

    var searchableText: String {
        [title, subtitle].compactMap { $0?.lowercased() }.joined(separator: " ")
    }

    init(workspaceIdentifier: String?, conversations: [Conversation], currentWorkspaceIdentifier: String?) {
        self.workspaceIdentifier = workspaceIdentifier
        self.conversations = conversations
        self.isCurrentWorkspace = workspaceIdentifier == currentWorkspaceIdentifier

        guard let workspaceIdentifier,
              let url = URL(string: workspaceIdentifier) else {
            self.title = "No Project"
            self.subtitle = nil
            return
        }

        self.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let abbreviatedPath = (url.path as NSString).abbreviatingWithTildeInPath
        self.subtitle = abbreviatedPath == title ? nil : abbreviatedPath
    }
}

private struct SidebarProjectRow: View {
    let group: SidebarProjectGroup
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: Carbon.spacingRelaxed) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.carbonTextTertiary)
                .frame(width: 10)

            Image(systemName: group.isUnassigned ? "tray" : (group.isCurrentWorkspace ? "folder.fill" : "folder"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(group.isCurrentWorkspace ? Color.carbonAccent : Color.carbonTextSecondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.carbonSans(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.carbonText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .lineLimit(1)
                        Text("·")
                    }
                    Text("\(group.conversations.count) chat\(group.conversations.count == 1 ? "" : "s")")
                    if group.isCurrentWorkspace {
                        Text("·")
                        Text("CURRENT")
                            .foregroundStyle(Color.carbonAccent)
                    }
                }
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct SidebarConversationRow: View {
    let conversation: Conversation
    let isCurrent: Bool
    let isNested: Bool

    var body: some View {
        HStack(spacing: Carbon.spacingRelaxed) {
            if isNested {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isCurrent ? Color.carbonAccent : Color.carbonBorder)
                    .frame(width: 2, height: 26)
                    .padding(.leading, 22)
            } else if isCurrent {
                Circle()
                    .fill(Color.carbonAccent)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(isCurrent
                        ? .carbonSans(.subheadline, weight: .semibold)
                        : .carbonSans(.subheadline))
                    .foregroundStyle(isCurrent ? Color.carbonText : Color.carbonTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(conversation.userMessageCount) msg\(conversation.userMessageCount == 1 ? "" : "s")")
                    Text("·")
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
