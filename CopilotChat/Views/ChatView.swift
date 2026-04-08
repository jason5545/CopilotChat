import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ConversationStore.self) private var conversationStore

    @State private var inputText = ""
    @State private var showToolPicker = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var editingMessageId: UUID?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachedImageData: Data?
    @State private var clipboardHasImage = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.carbonBlack.ignoresSafeArea()

                VStack(spacing: 0) {
                    messagesList
                    inputBar
                }
            }
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("COPILOT")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
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
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if let usage = copilotService.tokenUsage, copilotService.contextWindow > 0 {
                            ContextRing(
                                promptTokens: usage.promptTokens,
                                contextWindow: copilotService.contextWindow
                            )
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
        }
    }

    // MARK: - Messages List

    /// Reversed-list chat scroll: the ScrollView is flipped vertically so new
    /// content appears at the scroll origin. No scrollTo needed during streaming.
    @State private var isScrolledUp = false
    @State private var scrollPosition: ScrollPosition = .init(edge: .top)

    private var messagesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if copilotService.isStreaming {
                    streamingIndicator.flippedForChat()
                }

                let dimmedIds = outOfContextIds
                let regenId = lastAssistantId

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
                        onRegenerate: (!copilotService.isStreaming && message.id == regenId) ? {
                            copilotService.regenerateLastResponse(tools: settingsStore.mcpTools)
                            Haptics.impact(.medium)
                        } : nil,
                        onDelete: copilotService.isStreaming ? nil : { msg in
                            copilotService.deleteMessage(msg.id)
                            autoSaveConversation()
                            Haptics.notification(.success)
                        }
                    )
                    .flippedForChat()
                    .opacity(dimmedIds.contains(message.id) ? 0.45 : 1.0)
                    .id(message.id)

                    if isSummary {
                        compactionDivider.flippedForChat()
                    }
                }

                if copilotService.messages.isEmpty {
                    emptyState.flippedForChat()
                }

                if let error = copilotService.streamingError {
                    errorBanner(error).flippedForChat()
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

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.carbonAccent.opacity(0.08))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(Color.carbonAccent.opacity(0.05))
                    .frame(width: 120, height: 120)
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.carbonAccent.opacity(0.6))
            }

            VStack(spacing: 8) {
                Text("Start a conversation")
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

                Text(settingsStore.selectedModel)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
                    .padding(.top, 2)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Streaming Indicator

    private var streamingIndicator: some View {
        HStack(spacing: 10) {
            ThinkingIndicator()
            Text(copilotService.isCompacting ? "Compacting" : "Thinking")
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

    private var outOfContextIds: Set<UUID> {
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
        ReasoningEffort.isSupported(model: settingsStore.selectedModel)
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

            if let imageData = attachedImageData, let uiImage = UIImage(data: imageData) {
                imagePreview(uiImage)
            }

            HStack(alignment: .bottom, spacing: 10) {
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

                if clipboardHasImage && attachedImageData == nil {
                    Button {
                        if let image = UIPasteboard.general.image {
                            attachedImageData = image.jpegData(compressionQuality: 0.7)
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

                TextField("Message", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.carbonSans(.body))
                    .foregroundStyle(Color.carbonText)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .onSubmit { sendCurrentMessage() }
                    .tint(Color.carbonAccent)

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
            .animation(.easeOut(duration: 0.2), value: copilotService.isStreaming)
            .padding(.horizontal, Carbon.messagePaddingH)
            .padding(.vertical, Carbon.spacingRelaxed)
            .background(Color.carbonSurface)
            .onAppear { checkClipboard() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                checkClipboard()
            }
        }
    }

    // MARK: - Thinking Effort Bar

    private var thinkingEffortBar: some View {
        @Bindable var store = settingsStore
        return HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.caption2)
                .foregroundStyle(
                    store.reasoningEffort == .off
                        ? Color.carbonTextTertiary
                        : Color.carbonAccent
                )

            Text("THINKING")
                .font(.carbonMono(.caption2, weight: .semibold))
                .foregroundStyle(Color.carbonTextTertiary)
                .kerning(0.8)

            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                let isSelected = store.reasoningEffort == effort
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        store.reasoningEffort = effort
                    }
                } label: {
                    Text(effort.label)
                        .font(.carbonMono(.caption2, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(
                            isSelected
                                ? (effort == .off ? Color.carbonTextSecondary : Color.carbonBlack)
                                : Color.carbonTextTertiary
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isSelected
                                ? (effort == .off ? Color.carbonElevated : Color.carbonAccent)
                                : Color.clear
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, 6)
        .background(Color.carbonSurface)
    }

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = attachedImageData != nil
        return (hasText || hasImage)
            && !copilotService.isStreaming
            && authManager.isAuthenticated
    }

    private func checkClipboard() {
        clipboardHasImage = UIPasteboard.general.hasImages
    }

    private func sendCurrentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = attachedImageData
        guard (!text.isEmpty || imageData != nil), !copilotService.isStreaming, authManager.isAuthenticated else { return }
        Haptics.impact(.medium)
        inputText = ""
        attachedImageData = nil

        if conversationStore.currentConversationId == nil {
            conversationStore.createConversation()
        }

        if let editId = editingMessageId {
            editingMessageId = nil
            copilotService.editAndResend(editId, newContent: text, tools: settingsStore.mcpTools)
        } else {
            copilotService.sendMessage(text, imageData: imageData, tools: settingsStore.mcpTools)
        }
    }

    private func startNewConversation() {
        conversationStore.startNewConversation(
            currentMessages: copilotService.messages,
            currentSummaryId: copilotService.summaryMessageId,
            currentReasoningEffort: settingsStore.reasoningEffort
        )
        copilotService.newConversation()
    }

    private func autoSaveConversation() {
        guard !copilotService.messages.isEmpty else { return }
        conversationStore.updateCurrentConversation(
            messages: copilotService.messages,
            summaryMessageId: copilotService.summaryMessageId,
            reasoningEffort: settingsStore.reasoningEffort
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
