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
                            .font(.carbonSans(.subheadline))
                            .foregroundStyle(Color.carbonTextSecondary)
                            .listRowBackground(Color.carbonSurface)
                    }

                    Section {
                        TextField("Model ID", text: $store.selectedModel)
                            .font(.carbonMono(.body))
                            .foregroundStyle(Color.carbonText)
                            .textInputAutocapitalization(.never)
                            .listRowBackground(Color.carbonSurface)
                    } header: {
                        CarbonSectionHeader(title: "Manual Entry")
                    }
                } else {
                    Section {
                        ForEach(copilotService.availableModels) { model in
                            Button {
                                settingsStore.selectedModel = model.id
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.displayName)
                                            .font(.carbonSans(.body))
                                            .foregroundStyle(Color.carbonText)
                                        HStack(spacing: 6) {
                                            if model.id != model.displayName {
                                                Text(model.id)
                                                    .font(.carbonMono(.caption2))
                                                    .foregroundStyle(Color.carbonTextTertiary)
                                            }
                                            if let tokens = model.displayContextWindowTokens, tokens > 0 {
                                                Text("\(formatTokenCount(tokens)) ctx")
                                                    .font(.carbonMono(.caption2))
                                                    .foregroundStyle(Color.carbonAccent.opacity(0.8))
                                            }
                                        }
                                    }
                                    Spacer()
                                    if settingsStore.selectedModel == model.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.carbonAccent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.carbonSurface)
                        }
                    } header: {
                        CarbonSectionHeader(title: "Available Models")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.carbonBlack)
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SELECT MODEL")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonAccent)
                    }
                }
            }
        }
    }

}
