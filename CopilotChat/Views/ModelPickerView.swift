import SwiftUI

struct ModelPickerView: View {
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = settingsStore

        NavigationStack {
            List {
                if copilotService.availableModels.isEmpty {
                    Section {
                        Text("No models loaded. Sign in to GitHub to fetch available models.")
                            .foregroundStyle(.secondary)
                    }

                    Section("Manual Entry") {
                        TextField("Model ID", text: $store.selectedModel)
                            .textInputAutocapitalization(.never)
                    }
                } else {
                    Section("Available Models") {
                        ForEach(copilotService.availableModels) { model in
                            Button {
                                settingsStore.selectedModel = model.id
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(model.displayName)
                                            .font(.body)
                                        if model.id != model.displayName {
                                            Text(model.id)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if settingsStore.selectedModel == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Select Model")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
