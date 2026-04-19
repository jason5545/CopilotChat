import SwiftUI

struct QuickSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuickSearchStore.self) private var quickSearchStore
    @Environment(ConversationStore.self) private var conversationStore
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore

    @State private var searchText = ""
    @State private var selectedResultID: String?
    @State private var pendingAction: (@MainActor () -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchHeader

                if filteredResults.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .background(Color.carbonBlack)
            .navigationTitle("Quick Search")
            .carbonNavigationBar()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("QUICK SEARCH")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .carbonTrailing) {
                    Button("Done") {
                        close()
                    }
                    .font(.carbonSans(.subheadline, weight: .medium))
                    .foregroundStyle(Color.carbonAccent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.carbonBlack)
        .onAppear {
            if isCodingMode, quickSearchStore.openIntent == .addProject {
                searchText = "/project "
            }
            selectedResultID = filteredResults.first?.id
        }
        .onChange(of: searchText) { _, _ in
            if !filteredResults.contains(where: { $0.id == selectedResultID }) {
                selectedResultID = filteredResults.first?.id
            }
        }
        .onDisappear {
            guard let action = pendingAction else { return }
            pendingAction = nil
            action()
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: Carbon.spacingRelaxed) {
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.carbonSans(.body))
                .foregroundStyle(Color.carbonText)
                .submitLabel(.search)
                .onSubmit {
                    performSelectedResult()
                }
                .padding(.horizontal, Carbon.spacingLoose)
                .padding(.vertical, 14)
                .background(Color.carbonSurface)
                .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                        .stroke(Color.carbonBorder.opacity(0.55), lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                QuickSearchHintChip(text: "new", detail: "New chat")
                QuickSearchHintChip(text: "settings", detail: "Open settings")
                if isCodingMode {
                    QuickSearchHintChip(text: "/project", detail: "Workspace")
                }
            }
        }
        .padding(Carbon.messagePaddingH)
        .background(Color.carbonBlack)
    }

    private var resultsList: some View {
        List {
            ForEach(groupedResults) { group in
                Section {
                    ForEach(group.items) { item in
                        Button {
                            perform(item)
                        } label: {
                            QuickSearchRow(item: item, isSelected: item.id == selectedResultID)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(item.id == selectedResultID ? Color.carbonElevated : Color.carbonSurface)
                    }
                } header: {
                    CarbonSectionHeader(title: group.title)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
    }

    private var emptyState: some View {
        VStack(spacing: Carbon.spacingRelaxed) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.carbonTextTertiary)
            VStack(spacing: Carbon.spacingTight) {
                Text("No Matches")
                    .font(.carbonSerif(.subheadline))
                    .foregroundStyle(Color.carbonTextSecondary)
                Text("Try another keyword or shortcut.")
                    .font(.carbonSans(.caption))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredResults: [QuickSearchResult] {
        switch searchMode {
        case .general(let query):
            let actions = availableQuickActions.filter { matches($0, query: query) }
            let projects = availableProjectResults.filter { matches($0, query: query) }
            let conversations = conversationResults.filter { matches($0, query: query) }
            return actions + projects + conversations
        case .project(let query):
            let actions = availableQuickActions.filter { $0.section == .actions && ($0.id == "action:workspace" || matches($0, query: query)) }
            let projects = availableProjectResults.filter { matches($0, query: query) }
            return actions + projects
        }
    }

    private var isCodingMode: Bool {
        settingsStore.appMode == .coding
    }

    private var searchPlaceholder: String {
        isCodingMode ? "Search actions, projects, and conversations..." : "Search actions and conversations..."
    }

    private var availableQuickActions: [QuickSearchResult] {
        isCodingMode ? quickActions : quickActions.filter { $0.id != "action:workspace" }
    }

    private var availableProjectResults: [QuickSearchResult] {
        isCodingMode ? projectResults : []
    }

    private var currentProjectIdentifier: String? {
        if settingsStore.appMode == .coding {
            return conversationStore.currentConversation?.workspaceIdentifier ?? ConversationStore.currentWorkspaceIdentifier
        }
        return conversationStore.currentConversation?.workspaceIdentifier
    }

    private var groupedResults: [QuickSearchSection] {
        var sections: [QuickSearchSection] = []

        let actions = filteredResults.filter { $0.section == .actions }
        if !actions.isEmpty {
            sections.append(QuickSearchSection(title: "Actions", items: actions))
        }

        let projects = filteredResults.filter { $0.section == .projects }
        if !projects.isEmpty {
            sections.append(QuickSearchSection(title: "Projects", items: projects))
        }

        let conversations = filteredResults.filter { $0.section == .conversations }
        if !conversations.isEmpty {
            sections.append(QuickSearchSection(title: "Conversations", items: conversations))
        }

        return sections
    }

    private var quickActions: [QuickSearchResult] {
        let workspaceSubtitle = WorkspaceManager.shared.currentURL?.path ?? "Pick a workspace for coding tools"

        return [
            QuickSearchResult(
                id: "action:new-chat",
                section: .actions,
                title: "New Conversation",
                subtitle: settingsStore.appMode == .coding ? "Start a fresh project chat" : "Start a fresh chat",
                metadata: settingsStore.appMode == .coding ? "CODING" : "CHAT",
                systemImage: "square.and.pencil",
                searchableText: "new conversation new chat new coding chat start fresh",
                action: {
                    ConversationNavigator.startNewConversation(
                        store: conversationStore,
                        copilotService: copilotService,
                        settingsStore: settingsStore
                    )
                }
            ),
            QuickSearchResult(
                id: "action:settings",
                section: .actions,
                title: "Open Settings",
                subtitle: "Providers, tools, and app preferences",
                metadata: "SYSTEM",
                systemImage: "gearshape",
                searchableText: "settings preferences configuration tools providers",
                action: {
                    NotificationCenter.default.post(name: .requestSettings, object: nil)
                }
            ),
            QuickSearchResult(
                id: "action:workspace",
                section: .actions,
                title: WorkspaceManager.shared.hasWorkspace ? "Change Project Folder" : "Select Project Folder",
                subtitle: workspaceSubtitle,
                metadata: WorkspaceManager.shared.hasWorkspace ? "WORKSPACE" : "PROJECT",
                systemImage: WorkspaceManager.shared.hasWorkspace ? "folder.badge.gearshape" : "folder.badge.plus",
                searchableText: "project folder workspace change select choose /project switch folder",
                action: {
                    let isAddProjectFlow = quickSearchStore.openIntent == .addProject || searchMode.isProjectMode
                    if isAddProjectFlow {
                        WorkspaceManager.shared.prepareForNewProjectSelection()
                    } else {
                        WorkspaceManager.shared.clearPendingWorkspaceSelection()
                    }
                    NotificationCenter.default.post(name: .requestWorkspaceSelection, object: nil)
                }
            )
        ]
    }

    private var projectResults: [QuickSearchResult] {
        var resultsById = Dictionary(uniqueKeysWithValues: conversationProjectResults.map { ($0.id, $0) })

        for result in savedWorkspaceProjectResults where resultsById[result.id] == nil {
            resultsById[result.id] = result
        }

        return resultsById.values.sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var conversationProjectResults: [QuickSearchResult] {
        let grouped = Dictionary(grouping: conversationStore.conversations) {
            WorkspaceManager.normalizedWorkspaceIdentifier($0.workspaceIdentifier)
        }

        return grouped.compactMap { workspaceIdentifier, conversations in
            let group = QuickSearchProjectGroup(
                workspaceIdentifier: workspaceIdentifier,
                conversations: conversations,
                currentWorkspaceIdentifier: currentProjectIdentifier
            )

            return QuickSearchResult(
                id: "project:\(group.id)",
                section: .projects,
                title: group.title,
                subtitle: group.subtitle,
                metadata: group.metadata,
                systemImage: group.isCurrentWorkspace ? "folder.fill" : (group.isUnassigned ? "tray" : "folder"),
                searchableText: group.searchableText,
                sortDate: group.latestUpdatedAt,
                action: {
                    if let conversation = conversationStore.conversations
                        .filter({ WorkspaceManager.shared.matchesWorkspaceIdentifiers($0.workspaceIdentifier, workspaceIdentifier) })
                        .sorted(by: { $0.updatedAt > $1.updatedAt })
                        .first {
                        ConversationNavigator.resumeConversation(
                            id: conversation.id,
                            store: conversationStore,
                            copilotService: copilotService,
                            settingsStore: settingsStore
                        )
                    } else {
                        NotificationCenter.default.post(name: .requestWorkspaceSelection, object: nil)
                    }
                }
            )
        }
    }

    private var savedWorkspaceProjectResults: [QuickSearchResult] {
        WorkspaceManager.shared.savedWorkspaces.compactMap { workspace in
            guard !conversationStore.conversations.contains(where: {
                WorkspaceManager.shared.matchesWorkspaceIdentifiers($0.workspaceIdentifier, workspace.id)
            }) else {
                return nil
            }

            return QuickSearchResult(
                id: "project:\(workspace.id)",
                section: .projects,
                title: workspace.title,
                subtitle: workspace.subtitle,
                metadata: workspace.isCurrent ? "CURRENT" : "SAVED",
                systemImage: workspace.isCurrent ? "folder.fill" : "folder",
                searchableText: [workspace.title.lowercased(), workspace.subtitle?.lowercased(), workspace.id.lowercased()]
                    .compactMap { $0 }
                    .joined(separator: " "),
                sortDate: workspace.isCurrent ? .distantFuture : .distantPast,
                action: {
                    openSavedWorkspace(workspace)
                }
            )
        }
    }

    private var conversationResults: [QuickSearchResult] {
        visibleConversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { conversation in
                let group = QuickSearchProjectGroup(
                    workspaceIdentifier: conversation.workspaceIdentifier,
                    conversations: [conversation],
                    currentWorkspaceIdentifier: currentProjectIdentifier
                )

                return QuickSearchResult(
                    id: "conversation:\(conversation.id.uuidString)",
                    section: .conversations,
                    title: conversation.title,
                    subtitle: group.title,
                    metadata: "\(conversation.userMessageCount) MSG",
                    systemImage: conversation.id == conversationStore.currentConversationId ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                    searchableText: [conversation.title.lowercased(), group.title.lowercased(), group.subtitle?.lowercased(), conversation.workspaceIdentifier?.lowercased()]
                        .compactMap { $0 }
                        .joined(separator: " "),
                    sortDate: conversation.updatedAt,
                    action: {
                        ConversationNavigator.resumeConversation(
                            id: conversation.id,
                            store: conversationStore,
                            copilotService: copilotService,
                            settingsStore: settingsStore
                        )
                    }
                )
            }
    }

    private var visibleConversations: [Conversation] {
        if isCodingMode {
            return conversationStore.conversations
        }

        return conversationStore.conversations.filter { $0.workspaceIdentifier == nil }
    }

    private func perform(_ item: QuickSearchResult) {
        pendingAction = item.action
        close()
    }

    private func openSavedWorkspace(_ workspace: WorkspaceManager.SavedWorkspace) {
        ConversationNavigator.startNewConversation(
            workspaceIdentifier: workspace.id,
            store: conversationStore,
            copilotService: copilotService,
            settingsStore: settingsStore
        )
    }

    private var selectedResult: QuickSearchResult? {
        filteredResults.first(where: { $0.id == selectedResultID }) ?? filteredResults.first
    }

    private var searchMode: QuickSearchMode {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        guard isCodingMode else {
            return .general(lowercased)
        }

        if lowercased == "/project" {
            return .project("")
        }

        if lowercased.hasPrefix("/project ") {
            let query = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return .project(query)
        }

        return .general(lowercased)
    }

    private func matches(_ item: QuickSearchResult, query: String) -> Bool {
        query.isEmpty || item.searchableText.contains(query)
    }

    private func performSelectedResult() {
        guard let selectedResult else { return }
        perform(selectedResult)
    }

    private func close() {
        quickSearchStore.dismiss()
        dismiss()
    }
}

private enum QuickSearchMode {
    case general(String)
    case project(String)

    var isProjectMode: Bool {
        switch self {
        case .project:
            return true
        case .general:
            return false
        }
    }
}

private struct QuickSearchSection: Identifiable {
    let title: String
    let items: [QuickSearchResult]

    var id: String { title }
}

private struct QuickSearchProjectGroup {
    let workspaceIdentifier: String?
    let title: String
    let subtitle: String?
    let metadata: String
    let isCurrentWorkspace: Bool
    let isUnassigned: Bool
    let searchableText: String
    let latestUpdatedAt: Date

    var id: String {
        workspaceIdentifier ?? "__unassigned__"
    }

    init(workspaceIdentifier: String?, conversations: [Conversation], currentWorkspaceIdentifier: String?) {
        self.workspaceIdentifier = workspaceIdentifier
        self.isCurrentWorkspace = WorkspaceManager.matchesWorkspaceIdentifiers(
            workspaceIdentifier,
            currentWorkspaceIdentifier
        )
        self.isUnassigned = workspaceIdentifier == nil
        self.latestUpdatedAt = conversations.map(\ .updatedAt).max() ?? .distantPast

        if let workspaceIdentifier,
           let url = URL(string: workspaceIdentifier) {
            title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            let abbreviatedPath = (url.path as NSString).abbreviatingWithTildeInPath
            subtitle = abbreviatedPath == title ? nil : abbreviatedPath
        } else {
            title = "No Project"
            subtitle = nil
        }

        metadata = isCurrentWorkspace ? "CURRENT" : "\(conversations.count) CHAT\(conversations.count == 1 ? "" : "S")"
        searchableText = [title.lowercased(), subtitle?.lowercased(), workspaceIdentifier?.lowercased()]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

private enum QuickSearchSectionKind {
    case actions
    case projects
    case conversations
}

private struct QuickSearchResult: Identifiable {
    let id: String
    let section: QuickSearchSectionKind
    let title: String
    let subtitle: String?
    let metadata: String?
    let systemImage: String
    let searchableText: String
    var sortDate: Date = .distantPast
    let action: @MainActor () -> Void
}

private struct QuickSearchRow: View {
    let item: QuickSearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Carbon.spacingRelaxed) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.carbonAccent : Color.carbonTextSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.carbonSans(.subheadline, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.carbonText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .lineLimit(1)
                    }
                    if let metadata = item.metadata, !metadata.isEmpty {
                        if item.subtitle != nil {
                            Text("·")
                        }
                        Text(metadata)
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

private struct QuickSearchHintChip: View {
    let text: String
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.carbonMono(.caption2, weight: .semibold))
            Text(detail)
                .font(.carbonSans(.caption))
        }
        .foregroundStyle(Color.carbonTextTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.carbonSurface)
        .clipShape(Capsule())
    }
}
