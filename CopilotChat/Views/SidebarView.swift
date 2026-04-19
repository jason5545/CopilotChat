import SwiftUI

struct SidebarView: View {
    @Environment(ConversationStore.self) private var store
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AuthManager.self) private var authManager

    @State private var searchText = ""
    @State private var expandedProjectIDs: Set<String> = []
    @State private var projectPendingDeletion: SidebarProjectGroup?

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

    private var currentProjectIdentifier: String? {
        if settingsStore.appMode == .coding {
            return store.currentConversation?.workspaceIdentifier ?? ConversationStore.currentWorkspaceIdentifier
        }
        return store.currentConversation?.workspaceIdentifier
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
        .confirmationDialog(
            "Delete project from CopilotChat?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        projectPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                if let group = projectPendingDeletion {
                    deleteProject(group)
                }
                projectPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            Text("This only removes the project from CopilotChat, including its conversations and saved folder access. The actual folder on disk is not deleted.")
        }
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
                SidebarProjectRow(
                    group: group,
                    isExpanded: isProjectExpanded(group.id),
                    onToggle: { toggleProject(group.id) },
                    onNewConversation: group.isUnassigned ? nil : { startNewConversation(in: group) },
                    onDeleteProject: group.isUnassigned ? nil : { projectPendingDeletion = group }
                )
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
        let grouped = Dictionary(grouping: store.conversations) {
            WorkspaceManager.normalizedWorkspaceIdentifier($0.workspaceIdentifier)
        }

        return grouped.compactMap { workspaceIdentifier, conversations in
            let sortedConversations = conversations.sorted { $0.updatedAt > $1.updatedAt }
            let group = SidebarProjectGroup(
                workspaceIdentifier: workspaceIdentifier,
                conversations: sortedConversations,
                currentWorkspaceIdentifier: currentProjectIdentifier
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
                currentWorkspaceIdentifier: currentProjectIdentifier
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
        ConversationNavigator.resumeConversation(
            id: id,
            store: store,
            copilotService: copilotService,
            settingsStore: settingsStore
        )
    }

    private func startNewConversation(in group: SidebarProjectGroup) {
        guard let workspaceIdentifier = group.workspaceIdentifier else { return }
        guard ConversationNavigator.startNewProjectConversation(
            workspaceIdentifier: workspaceIdentifier,
            store: store,
            copilotService: copilotService,
            settingsStore: settingsStore
        ) else {
            return
        }
        expandedProjectIDs.insert(group.id)
    }

    private func deleteProject(_ group: SidebarProjectGroup) {
        guard let workspaceIdentifier = group.workspaceIdentifier else { return }

        let isCurrentProject = WorkspaceManager.matchesWorkspaceIdentifiers(
            currentProjectIdentifier,
            workspaceIdentifier
        )

        store.deleteProjectConversations(matching: workspaceIdentifier)
        WorkspaceManager.shared.removeWorkspaceReference(matching: workspaceIdentifier)
        expandedProjectIDs.remove(group.id)

        if isCurrentProject {
            copilotService.stopStreaming()
            copilotService.newConversation()
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
        self.isCurrentWorkspace = WorkspaceManager.matchesWorkspaceIdentifiers(
            workspaceIdentifier,
            currentWorkspaceIdentifier
        )

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
    let onToggle: () -> Void
    let onNewConversation: (() -> Void)?
    let onDeleteProject: (() -> Void)?

    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        HStack(spacing: Carbon.spacingTight) {
            Button(action: onToggle) {
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

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onNewConversation {
                Button(action: onNewConversation) {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(Color.carbonTextSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .opacity(isHovered || group.isCurrentWorkspace ? 1 : 0)
                .allowsHitTesting(isHovered || group.isCurrentWorkspace)
                #endif
                .accessibilityLabel("New conversation in \(group.title)")
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let onDeleteProject {
                Button(role: .destructive, action: onDeleteProject) {
                    Label("Delete Project", systemImage: "trash")
                }
            }
        }
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
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
