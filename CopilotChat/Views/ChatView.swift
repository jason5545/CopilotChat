#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

struct ChatView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ConversationStore.self) private var conversationStore
    @Environment(QuickSearchStore.self) private var quickSearchStore

    var showToolbar: Bool = true

@State private var inputText = ""
    @State private var showToolPicker = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showModePicker = false
    @State private var showWorkspaceSelector = false
    @State private var terminalSessionTracker = TerminalSessionTracker.shared
    @State private var editingMessageId: UUID?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachedImageData: Data?
    @State private var clipboardHasImage = false
    @FocusState private var isInputFocused: Bool
    @State private var mentionQuery: String?
    @State private var mentionManager = FileMentionManager()
    @State private var mentionedFiles: [FileMention] = []

    var body: some View {
        @Bindable var terminalTracker = terminalSessionTracker

        NavigationStack {
            ZStack {
                Color.carbonBlack.ignoresSafeArea()

                VStack(spacing: 0) {
                    messagesList
                    inputBar
                }
            }
            .carbonNavigationBar()
            #if canImport(UIKit)
            .toolbar(showToolbar ? .visible : .hidden, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if !usesCompactPhoneToolbar {
                        Text("COPILOT")
                            .font(.carbonMono(.caption, weight: .bold))
                            .kerning(2.5)
                            .foregroundStyle(Color.carbonText)
                    }
                }
                ToolbarItem(placement: .carbonLeading) {
                    HStack(spacing: 14) {
                        if showsMobileProjectSwitcher {
                            Button {
                                quickSearchStore.present(.addProject)
                            } label: {
                                Image(systemName: "folder")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.carbonTextSecondary)
                            }
                        }
                        Button {
                            quickSearchStore.present()
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(Color.carbonTextSecondary)
                        }
                        if !usesCompactPhoneToolbar {
                            Button {
                                showHistory = true
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.carbonTextSecondary)
                            }
                            Button {
                                startNewConversation()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.carbonTextSecondary)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .carbonTrailing) {
                    HStack(spacing: 12) {
                        if let usage = copilotService.tokenUsage,
                           copilotService.contextWindow > 0 {
                            ContextRing(
                                promptTokens: usage.promptTokens,
                                contextWindow: copilotService.contextWindow,
                                style: usesCompactPhoneToolbar ? .compact : .inline
                            )
                        }

                        Button {
                            settingsStore.appMode = settingsStore.appMode == .chat ? .coding : .chat
                        } label: {
                            Image(systemName: settingsStore.appMode.icon)
                                .font(.subheadline)
                            .foregroundStyle(settingsStore.appMode == .coding ? Color.carbonAccent : Color.carbonTextSecondary)
                            .frame(width: 28, height: 28)
                            .padding(.vertical, 4)
                            .background(settingsStore.appMode == .coding ? Color.carbonAccentMuted : Color.carbonElevated)
                            .clipShape(Capsule())
                        }

                        Menu {
                            if usesCompactPhoneToolbar {
                                Button {
                                    startNewConversation()
                                } label: {
                                    Label("New Conversation", systemImage: "square.and.pencil")
                                }
                                Button {
                                    showHistory = true
                                } label: {
                                    Label("History", systemImage: "clock.arrow.circlepath")
                                }
                                Divider()
                            }
                            if settingsStore.appMode == .coding {
                                Button {
                                    settingsStore.toolAccessMode = .supervised
                                } label: {
                                    Label("Supervised", systemImage: "lock")
                                }
                                Button {
                                    settingsStore.toolAccessMode = .autoApprove
                                } label: {
                                    Label("Auto-accept edits", systemImage: "pencil.line")
                                }
                                Button {
                                    settingsStore.toolAccessMode = .fullAccess
                                } label: {
                                    Label("Full access", systemImage: "lock.open")
                                }
                            } else {
                                Button {
                                    settingsStore.toolAccessMode = .alwaysLoaded
                                } label: {
                                    Label("Tools always loaded", systemImage: "wrench.and.screwdriver.fill")
                                }
                                Button {
                                    settingsStore.toolAccessMode = .loadWhenNeeded
                                } label: {
                                    Label("Load tools when needed", systemImage: "magnifyingglass")
                                }
                            }
                        } label: {
                            Image(systemName: toolAccessMenuIcon)
                                .font(.subheadline)
                                .foregroundStyle(Color.carbonTextSecondary)
                                .frame(width: 28, height: 28)
                                .padding(.vertical, 4)
                                .background(Color.carbonElevated)
                                .clipShape(Capsule())
                        }

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.subheadline)
                                .foregroundStyle(Color.carbonTextSecondary)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showHistory) {
                ConversationHistoryView()
            }
            .sheet(isPresented: $showToolPicker) {
                MCPToolPickerView { tool in
                    showToolPicker = false
                    copilotService.sendMessage("[Calling tool: \(tool.name)]", tools: settingsStore.mcpTools)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showWorkspaceSelector) {
                WorkspaceSelectorView()
            }
            .sheet(isPresented: $terminalTracker.isWindowPresented, onDismiss: {
                terminalSessionTracker.focusedSessionId = nil
            }) {
                TerminalWindowView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestWorkspaceSelection)) { _ in
                showWorkspaceSelector = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestQuickSearch)) { _ in
                quickSearchStore.present()
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceDidChange)) { _ in
                mentionedFiles.removeAll()
                mentionQuery = nil
                mentionManager.refreshWorkspaceIndexIfNeeded(force: true)
            }
        }
    }

    // MARK: - Messages List

    /// Reversed-list chat scroll: the ScrollView is flipped vertically so new
    /// content appears at the scroll origin. No scrollTo needed during streaming.
    @State private var isScrolledUp = false
    @State private var scrollPosition: ScrollPosition = .init(edge: .top)
    @State private var cachedOutOfContextIds: Set<UUID> = []
    @Environment(\.scenePhase) private var scenePhase

    private var messagesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if copilotService.isStreaming {
                    streamingIndicator
                        .flippedForChat()
                }

                ForEach(copilotService.messages.reversed()) { message in
                    let isLast = message.id == copilotService.messages.last?.id
                    let isSummary = message.id == copilotService.summaryMessageId
                    MessageView(
                        message: message,
                        toolCallStatuses: copilotService.toolCallStatuses,
                        toolCallServerNames: copilotService.toolCallServerNames,
                        isStreaming: isLast && copilotService.isStreaming,
                        onRetryToolCall: { toolCall in
                            copilotService.retryToolCall(toolCall, tools: settingsStore.mcpTools)
                        },
                        onPermissionDecision: { decision in
                            copilotService.resolvePermission(decision)
                        },
                        isSummary: isSummary,
                        onEdit: copilotService.isStreaming ? nil : { msg in
                            editingMessageId = msg.id
                            inputText = msg.content
                            isInputFocused = true
                            Haptics.impact(.light)
                        },
                        onRegenerate: (!copilotService.isStreaming && message.id == lastAssistantId) ? {
                            copilotService.regenerateLastResponse(tools: settingsStore.mcpTools)
                            Haptics.impact(.medium)
                        } : nil
                    )
                    .flippedForChat()
                    .contextMenu {
                        if message.role == .user || message.role == .assistant {
                            if !message.content.isEmpty {
                                Button {
                                    Haptics.copyToClipboard(message.content)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                ShareLink(item: message.content) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            if !copilotService.isStreaming {
                                Button(role: .destructive) {
                                    copilotService.deleteMessage(message.id)
                                    autoSaveConversation()
                                    Haptics.notification(.success)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } preview: {
                        MessageContextPreview(message: message)
                    }
                    .opacity(cachedOutOfContextIds.contains(message.id) ? 0.45 : 1.0)
                    .id(message.id)

                    if isSummary {
                        compactionDivider
                            .flippedForChat()
                    }
                }

                if copilotService.messages.isEmpty {
                    emptyStateContent
                        .flippedForChat()
                }

                if let error = copilotService.streamingError {
                    errorBanner(error)
                        .flippedForChat()
                }
            }
            .padding(.vertical, Carbon.spacingBase)
        }
        .scrollPosition($scrollPosition)
        .flippedForChat()
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y > 300
        } action: { _, scrolledAway in
            isScrolledUp = scrolledAway
        }
        .onChange(of: copilotService.isStreaming) {
            if !copilotService.isStreaming {
                autoSaveConversation()
            }
        }
        .onChange(of: copilotService.summaryMessageId) { _, _ in
            cachedOutOfContextIds = computeOutOfContextIds()
        }
        .onChange(of: copilotService.messages.count) { _, _ in
            cachedOutOfContextIds = computeOutOfContextIds()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                copilotService.stopStreaming()
            }
        }
        .overlay(alignment: .bottom) {
            if isScrolledUp {
                Button {
                    scrollPosition.scrollTo(edge: .top)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.caption.bold())
                        .foregroundStyle(Color.carbonText)
                        .frame(width: 32, height: 32)
                        .background(Color.carbonElevated)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                }
                .padding(.bottom, 10)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isScrolledUp)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateContent: some View {
        if settingsStore.appMode == .coding {
            emptyStateCoding
        } else {
            emptyStateDefault
        }
    }

    private var emptyStateDefault: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.carbonAccent.opacity(0.08))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(Color.carbonAccent.opacity(0.05))
                    .frame(width: 120, height: 120)
                Image(systemName: settingsStore.appMode == .coding ? "chevron.left.forwardslash.chevron.right" : "bubble.left")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.carbonAccent.opacity(0.6))
            }

            VStack(spacing: 8) {
                Text(settingsStore.appMode == .coding ? "Start coding" : "Start a conversation")
                    .font(.carbonSerif(.title3, weight: .medium))
                    .foregroundStyle(Color.carbonText)

                if !authManager.isAuthenticated {
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.key")
                                .font(.caption)
                            Text("Sign in to GitHub")
                                .font(.carbonMono(.caption, weight: .medium))
                        }
                        .foregroundStyle(Color.carbonBlack)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.carbonAccent)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }

                if let providerModelLabel {
                    Text(providerModelLabel)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var emptyStateCoding: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.carbonAccent.opacity(0.08))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(Color.carbonAccent.opacity(0.05))
                    .frame(width: 120, height: 120)
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.carbonAccent.opacity(0.8))
            }

            VStack(spacing: 8) {
                Text(WorkspaceManager.shared.trackedHasWorkspace ? "Start coding" : "Select a project folder")
                    .font(.carbonSerif(.title3, weight: .medium))
                    .foregroundStyle(Color.carbonText)

                if let workspaceName = WorkspaceManager.shared.trackedWorkspaceName,
                   WorkspaceManager.shared.trackedHasWorkspace {
                    Text(workspaceName)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .padding(.top, 2)
                }

                if let providerModelLabel {
                    Text(providerModelLabel)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }

                Button {
                    showWorkspaceSelector = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                        Text(WorkspaceManager.shared.trackedHasWorkspace ? "Change Folder" : "Choose Folder")
                            .font(.carbonMono(.caption, weight: .medium))
                    }
                    .foregroundStyle(Color.carbonBlack)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.carbonAccent)
                    .clipShape(Capsule())
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Streaming Indicator

    private var providerModelLabel: String? {
        let providerName = copilotService.providerRegistry?.activeProvider()?.displayName
        let modelName = copilotService.providerRegistry?.activeModelId ?? settingsStore.selectedModel

        if let providerName, !providerName.isEmpty, !modelName.isEmpty {
            return "\(providerName) · \(modelName)"
        }

        return modelName.isEmpty ? nil : modelName
    }

    /// Label for the streaming indicator based on actual model state.
    private var streamingLabel: String {
        if copilotService.isCompacting { return "Compacting" }
        if let last = copilotService.messages.last,
           last.role == .assistant,
           last.reasoning != nil,
           last.content.isEmpty {
            return "Thinking"
        }
        return "Responding"
    }

    private var streamingIndicator: some View {
        HStack(spacing: 10) {
            ThinkingIndicator()
            Text(streamingLabel)
                .font(.carbonMono(.caption2, weight: .medium))
                .foregroundStyle(copilotService.isCompacting ? Color.carbonWarning : Color.carbonTextTertiary)
            Spacer()
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingBase)
        .id("streaming-indicator")
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.carbonError)
                .font(.caption)
            Text(error)
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonError)
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingBase)
    }

    // MARK: - Image Preview

    #if canImport(UIKit)
    private func imagePreview(_ image: UIImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))

                Button {
                    attachedImageData = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.carbonText)
                        .background(Color.carbonBlack.clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            Spacer()
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, 6)
        .background(Color.carbonSurface)
    }
    #elseif canImport(AppKit)
    private func imagePreviewNS(_ image: NSImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))

                Button {
                    attachedImageData = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.carbonText)
                        .background(Color.carbonBlack.clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            Spacer()
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, 6)
        .background(Color.carbonSurface)
    }
    #endif

    // MARK: - Edit & Regenerate

    private var lastAssistantId: UUID? {
        copilotService.messages.last { $0.role == .assistant && $0.id != copilotService.summaryMessageId }?.id
    }

    private var editingIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.caption2)
            Text("EDITING")
                .font(.carbonMono(.caption2, weight: .semibold))
                .kerning(0.8)
            Spacer()
            Button {
                editingMessageId = nil
                inputText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.carbonTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.carbonAccent)
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, 6)
        .background(Color.carbonSurface)
    }

    // MARK: - Compaction UX

    private func computeOutOfContextIds() -> Set<UUID> {
        guard let summaryId = copilotService.summaryMessageId,
              let summaryIndex = copilotService.messages.firstIndex(where: { $0.id == summaryId })
        else { return [] }
        return Set(copilotService.messages[..<summaryIndex].map(\.id))
    }

    private var compactionDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.carbonBorder.opacity(0.3))
                .frame(height: 0.5)
            Text("NOT IN CONTEXT")
                .font(.carbonMono(.caption2, weight: .medium))
                .foregroundStyle(Color.carbonTextTertiary)
                .kerning(0.8)
                .fixedSize()
            Rectangle()
                .fill(Color.carbonBorder.opacity(0.3))
                .frame(height: 0.5)
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingBase)
    }

    // MARK: - Input Bar

    private var showThinkingChip: Bool {
        !availableEffortLevels.isEmpty
    }

    /// Effort levels available for the current model/provider, from ProviderTransform.
    private var availableEffortLevels: [ReasoningEffort] {
        let modelId = copilotService.providerRegistry?.activeModelId
            ?? settingsStore.selectedModel
        let registry = copilotService.providerRegistry
        let providerId = registry?.activeProviderId ?? ""
        let mdProvider = registry?.modelsDevProviders[providerId]
        let efforts = ProviderTransform.availableEfforts(
            modelId: modelId,
            npm: mdProvider?.npm,
            model: mdProvider?.models[modelId],
            providerId: providerId)
        return efforts.isEmpty ? [] : [.off] + efforts
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.carbonBorder.opacity(0.4))
                .frame(height: 0.5)

            if showThinkingChip {
                thinkingEffortBar
            }

            if editingMessageId != nil {
                editingIndicator
            }

            if let imageData = attachedImageData {
                #if canImport(UIKit)
                if let uiImage = UIImage(data: imageData) {
                    imagePreview(uiImage)
                }
                #elseif canImport(AppKit)
                if let nsImage = NSImage(data: imageData) {
                    imagePreviewNS(nsImage)
                }
                #endif
            }

            if allowsFileMentions, !mentionedFiles.isEmpty {
                fileChipsBar
            }

            if allowsFileMentions, mentionQuery != nil {
                FileMentionPicker(
                    files: mentionManager.filteredFiles,
                    onSelect: { file in insertMention(file) },
                    query: mentionQuery ?? ""
                )
                .padding(.horizontal, Carbon.messagePaddingH)
                .padding(.top, Carbon.spacingTight)
                .background(Color.carbonSurface)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ProviderModelPicker()

                if !settingsStore.mcpTools.isEmpty {
                    Button {
                        showToolPicker = true
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.subheadline)
                            .foregroundStyle(Color.carbonTextTertiary)
                            .frame(width: 28, height: 28)
                    }
                }

                #if canImport(UIKit)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.subheadline)
                        .foregroundStyle(attachedImageData != nil ? Color.carbonAccent : Color.carbonTextTertiary)
                        .frame(width: 28, height: 28)
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            attachedImageData = uiImage.jpegData(compressionQuality: 0.7)
                            Haptics.impact(.light)
                        }
                        selectedPhotoItem = nil
                    }
                }
                #endif

                if clipboardHasImage && attachedImageData == nil {
                    Button {
                        if let data = PlatformHelpers.clipboardImage() {
                            attachedImageData = data
                            clipboardHasImage = false
                            Haptics.impact(.light)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.subheadline)
                            .foregroundStyle(Color.carbonAccent)
                            .frame(width: 28, height: 28)
                    }
                }

                TextField(inputPlaceholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.carbonSans(.body))
                    .foregroundStyle(Color.carbonText)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .onSubmit { sendCurrentMessage() }
                    .tint(Color.carbonAccent)
                    .onChange(of: inputText) { _, newText in
                        if allowsFileMentions {
                            detectMentionTrigger(newText)
                        } else if mentionQuery != nil {
                            mentionQuery = nil
                        }
                    }

                if copilotService.isStreaming {
                    Button {
                        copilotService.stopStreaming()
                        Haptics.impact(.medium)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.carbonError)
                            .frame(width: 12, height: 12)
                            .frame(width: 28, height: 28)
                            .background(Color.carbonError.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        sendCurrentMessage()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.caption.bold())
                            .foregroundStyle(canSend ? Color.carbonBlack : Color.carbonTextTertiary)
                            .frame(width: 28, height: 28)
                            .background(canSend ? Color.carbonAccent : Color.carbonElevated)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Carbon.messagePaddingH)
            .padding(.vertical, Carbon.spacingRelaxed)
            .background(Color.carbonSurface)
            .onAppear {
                checkClipboard()
                mentionManager.refreshWorkspaceIndexIfNeeded()
            }
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                checkClipboard()
            }
            #endif
        }
    }

    // MARK: - Thinking Effort Bar

    private var thinkingEffortBar: some View {
        @Bindable var store = settingsStore
        let levels = availableEffortLevels
        let isActive = store.reasoningEffort != .off
        let activeEfforts = levels.filter { $0 != .off }

        return HStack(spacing: 0) {
            thinkingToggleButton(isActive: isActive, activeEfforts: activeEfforts)

            if isActive {
                effortSegments(activeEfforts: activeEfforts)
            }

            Spacer()
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, 5)
        .background(Color.carbonSurface)
        .onChange(of: levels) {
            if !levels.contains(store.reasoningEffort) {
                store.reasoningEffort = .off
            }
        }
    }

    private func thinkingToggleButton(
        isActive: Bool, activeEfforts: [ReasoningEffort]
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                if isActive {
                    settingsStore.reasoningEffort = .off
                } else {
                    let fallback: ReasoningEffort = activeEfforts.contains(.medium) ? .medium
                        : (activeEfforts.contains(.high) ? .high : activeEfforts.first ?? .off)
                    settingsStore.reasoningEffort = fallback
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .medium))
                if !isActive {
                    Text("THINK")
                        .font(.carbonMono(.caption2, weight: .semibold))
                        .kerning(0.6)
                }
            }
            .foregroundStyle(isActive ? Color.carbonBlack : Color.carbonTextTertiary)
            .padding(.horizontal, isActive ? 7 : 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.carbonAccent : Color.carbonElevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func effortSegments(
        activeEfforts: [ReasoningEffort]
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(activeEfforts, id: \.self) { effort in
                effortButton(effort: effort, activeEfforts: activeEfforts)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.carbonBorder.opacity(0.5), lineWidth: 0.5))
        .padding(.leading, 6)
        .transition(.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private func effortButton(
        effort: ReasoningEffort, activeEfforts: [ReasoningEffort]
    ) -> some View {
        let isSelected = settingsStore.reasoningEffort == effort
        let idx = activeEfforts.firstIndex(of: effort) ?? 0
        let total = activeEfforts.count
        let intensity = Double(idx) / Double(max(total - 1, 1))

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                settingsStore.reasoningEffort = effort
                Haptics.impact(.light)
            }
        } label: {
            Text(effort.label)
                .font(.carbonMono(.caption2, weight: isSelected ? .bold : .medium))
                .kerning(0.3)
                .foregroundStyle(isSelected ? Color.carbonBlack : Color.carbonTextTertiary)
                .frame(minWidth: 28)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .background(isSelected ? Color.carbonAccent : Color.carbonAccent.opacity(0.04 + intensity * 0.08))
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Chips

    private var fileChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Carbon.spacingTight) {
                ForEach(mentionedFiles) { file in
                    fileChip(file)
                }
            }
            .padding(.horizontal, Carbon.messagePaddingH)
            .padding(.vertical, Carbon.spacingTight)
        }
        .background(Color.carbonElevated.opacity(0.5))
    }

    private func fileChip(_ file: FileMention) -> some View {
        HStack(spacing: 4) {
            Image(systemName: file.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(file.tintColor)

            Text(file.fileName)
                .font(.carbonMono(.caption2, weight: .medium))
                .foregroundStyle(Color.carbonText)
                .lineLimit(1)

            Button {
                removeMention(file)
                Haptics.impact(.light)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.carbonElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.carbonBorder.opacity(0.5), lineWidth: 0.5))
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = attachedImageData != nil
        let hasMentions = !mentionedFiles.isEmpty
        return (hasText || hasImage || hasMentions)
            && !copilotService.isStreaming
            && authManager.isAuthenticated
    }

    // MARK: - @ Mention Detection

    private func onInputChange(_ newText: String) {
        inputText = newText
        if allowsFileMentions {
            detectMentionTrigger(newText)
        } else {
            mentionQuery = nil
        }
    }

    private func detectMentionTrigger(_ text: String) {
        guard allowsFileMentions else {
            mentionQuery = nil
            return
        }

        guard text.contains("@") else {
            mentionQuery = nil
            return
        }

        let cursorPos = text.count
        let prefix = String(text.prefix(cursorPos))

        if let atRange = prefix.range(of: "@", options: .backwards) {
            let afterAt = String(prefix[atRange.upperBound...])
            if !afterAt.contains(" ") && !afterAt.contains("\n") {
                mentionQuery = afterAt.isEmpty ? "" : afterAt
                if mentionQuery != nil {
                    mentionManager.search(query: mentionQuery ?? "")
                }
                return
            }
        }
        mentionQuery = nil
    }

    private func insertMention(_ file: FileMention) {
        guard allowsFileMentions else { return }
        guard let query = mentionQuery else { return }

        if let atRange = inputText.range(of: "@\(query)", options: .backwards) {
            inputText.replaceSubrange(atRange, with: "")
        }

        if !mentionedFiles.contains(file) {
            mentionedFiles.append(file)
        }

        mentionQuery = nil
        isInputFocused = true
    }

    private func removeMention(_ file: FileMention) {
        guard allowsFileMentions else { return }
        mentionedFiles.removeAll { $0.id == file.id }
    }

    private func buildFileContext() -> String {
        guard allowsFileMentions else { return "" }
        guard !mentionedFiles.isEmpty else { return "" }

        var parts: [String] = []
        for file in mentionedFiles {
            if let content = mentionManager.readFileContent(file) {
                let truncated: String
                if content.count > 8000 {
                    truncated = String(content.prefix(8000)) + "\n... (truncated)"
                } else {
                    truncated = content
                }
                parts.append("=== \(file.relativePath) ===\n\(truncated)")
            } else {
                parts.append("=== \(file.relativePath) ===\n(file could not be read)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private func checkClipboard() {
        clipboardHasImage = PlatformHelpers.clipboardHasImages()
    }

    private var activeWorkspaceIdentifier: String? {
        settingsStore.appMode == .coding ? ConversationStore.currentWorkspaceIdentifier : nil
    }

    private var allowsFileMentions: Bool {
        settingsStore.appMode == .coding
    }

    private var inputPlaceholder: String {
        allowsFileMentions ? "Message (@ to mention file)" : "Message"
    }

    private var toolAccessMenuIcon: String {
        if settingsStore.appMode == .coding {
            return settingsStore.toolAccessMode.icon
        }

        return settingsStore.toolAccessMode == .loadWhenNeeded ? ToolAccessMode.loadWhenNeeded.icon : ToolAccessMode.alwaysLoaded.icon
    }

    private var usesCompactPhoneToolbar: Bool {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var showsMobileProjectSwitcher: Bool {
        usesCompactPhoneToolbar && settingsStore.appMode == .coding
    }

    private func sendCurrentMessage() {
        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = attachedImageData
        let fileContext = buildFileContext()
        if !fileContext.isEmpty {
            if text.isEmpty {
                text = "Refer to the following files:\n\n\(fileContext)"
            } else {
                text = "\(text)\n\n\(fileContext)"
            }
        }
        guard (!text.isEmpty || imageData != nil), !copilotService.isStreaming, authManager.isAuthenticated else { return }
        Haptics.impact(.medium)
        inputText = ""
        attachedImageData = nil
        mentionedFiles.removeAll()
        mentionQuery = nil

        if conversationStore.currentConversationId == nil {
            conversationStore.createConversation(workspaceIdentifier: activeWorkspaceIdentifier)
        }

        if let editId = editingMessageId {
            editingMessageId = nil
            copilotService.editAndResend(editId, newContent: text, tools: settingsStore.mcpTools)
        } else {
            copilotService.sendMessage(text, imageData: imageData, tools: settingsStore.mcpTools)
        }
    }

    private func startNewConversation() {
        inputText = ""
        mentionedFiles.removeAll()
        mentionQuery = nil
        ConversationNavigator.startNewConversation(
            store: conversationStore,
            copilotService: copilotService,
            settingsStore: settingsStore
        )
    }

    private func autoSaveConversation() {
        guard !copilotService.messages.isEmpty else { return }
        conversationStore.updateCurrentConversation(
            messages: copilotService.messages,
            summaryMessageId: copilotService.summaryMessageId,
            reasoningEffort: settingsStore.reasoningEffort,
            autoTitle: copilotService.autoGeneratedTitle,
            providerId: copilotService.providerRegistry?.activeProviderId,
            modelId: copilotService.providerRegistry?.activeModelId,
            workspaceIdentifier: activeWorkspaceIdentifier
        )
    }
}

// MARK: - MCP Tool Picker

struct MCPToolPickerView: View {
    @Environment(SettingsStore.self) private var settingsStore
    let onSelect: (MCPTool) -> Void

    var body: some View {
        NavigationStack {
            List(settingsStore.mcpTools) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(tool.name)
                                .font(.carbonMono(.subheadline, weight: .semibold))
                                .foregroundStyle(Color.carbonText)
                            Spacer()
                            Text(tool.serverName)
                                .font(.carbonMono(.caption2))
                                .foregroundStyle(Color.carbonTextTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.carbonElevated)
                                .clipShape(Capsule())
                        }
                        Text(tool.description)
                            .font(.carbonSans(.caption))
                            .foregroundStyle(Color.carbonTextSecondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.carbonSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.carbonBlack)
            .navigationTitle("MCP Tools")
            .toolbarTitleDisplayMode(.inline)
        }
    }
}
