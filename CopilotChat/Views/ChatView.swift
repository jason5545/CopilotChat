import SwiftUI

struct ChatView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore

    @State private var inputText = ""
    @State private var showToolPicker = false
    @State private var showSettings = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messagesList
                inputBar
            }
            .navigationTitle("Copilot Chat")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        copilotService.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showToolPicker) {
                MCPToolPickerView { tool in
                    showToolPicker = false
                    Task { await executeManualToolCall(tool) }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Messages List

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if copilotService.messages.isEmpty {
                        emptyState
                    }

                    ForEach(copilotService.messages) { message in
                        MessageView(message: message) { toolCall in
                            Task { await executeToolCall(toolCall) }
                        }
                        .id(message.id)
                    }

                    if copilotService.isStreaming {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop") {
                                copilotService.stopStreaming()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }

                    if let error = copilotService.streamingError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding()
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: copilotService.messages.last?.content) {
                if let last = copilotService.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !authManager.isAuthenticated {
                Button("Sign in to GitHub") {
                    showSettings = true
                }
                .buttonStyle(.borderedProminent)
            }
            Text(settingsStore.selectedModel)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                if !settingsStore.mcpTools.isEmpty {
                    Button {
                        showToolPicker = true
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Message", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .onSubmit { sendCurrentMessage() }

                Button {
                    sendCurrentMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.blue : Color.gray.opacity(0.3))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !copilotService.isStreaming
        && authManager.isAuthenticated
    }

    private func sendCurrentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !copilotService.isStreaming, authManager.isAuthenticated else { return }
        inputText = ""
        copilotService.sendMessage(text, tools: settingsStore.mcpTools)
    }

    // MARK: - Tool Execution

    private func executeToolCall(_ call: ToolCall) async {
        do {
            let result = try await settingsStore.callTool(name: call.function.name, argumentsJSON: call.function.arguments)
            copilotService.sendToolResult(
                toolCallId: call.id,
                toolName: call.function.name,
                result: result,
                tools: settingsStore.mcpTools
            )
        } catch {
            copilotService.sendToolResult(
                toolCallId: call.id,
                toolName: call.function.name,
                result: "Error: \(error.localizedDescription)",
                tools: settingsStore.mcpTools
            )
        }
    }

    private func executeManualToolCall(_ tool: MCPTool) async {
        // For manual tool calls, add a user message indicating the action
        copilotService.sendMessage("[Calling tool: \(tool.name)]", tools: settingsStore.mcpTools)
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tool.name)
                                .font(.headline)
                            Spacer()
                            Text(tool.serverName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("MCP Tools")
            .toolbarTitleDisplayMode(.inline)
        }
    }
}
