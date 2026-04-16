import SwiftUI

struct ProviderModelPicker: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(CopilotService.self) private var copilotService

    var body: some View {
        Menu {
            menuContent
        } label: {
            labelView
        }
    }

    // MARK: - Label

    private var labelView: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: activeProviderId))
                .font(.system(size: 12))
                .foregroundStyle(providerColor(for: activeProviderId))

            Text(displayModelName)
                .font(.carbonMono(.caption2, weight: .medium))
                .foregroundStyle(Color.carbonTextSecondary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.carbonTextTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.carbonElevated)
        .clipShape(Capsule())
    }

    // MARK: - Menu Content

    @ViewBuilder
    private var menuContent: some View {
        if let registry = copilotService.providerRegistry {
            configuredProvidersSection(registry: registry)
            Divider()
            browseProvidersSection(registry: registry)
        }
    }

    @ViewBuilder
    private func configuredProvidersSection(registry: ProviderRegistry) -> some View {
        let providers = registry.configuredProviders
        if providers.isEmpty {
            Text("No providers configured")
        } else {
            Section("Configured") {
                ForEach(providers, id: \.id) { provider in
                    providerButton(provider: provider, registry: registry)
                }
            }
        }
    }

    @ViewBuilder
    private func browseProvidersSection(registry: ProviderRegistry) -> some View {
        let configured = registry.configuredProviders
        let browse = registry.allProvidersSorted.filter { p in
            !configured.contains(where: { $0.id == p.id })
        }
        if !browse.isEmpty {
            Section("Browse") {
                ForEach(Array(browse.prefix(20)), id: \.id) { provider in
                    providerButton(provider: provider, registry: registry)
                }
            }
        }
    }

    @ViewBuilder
    private func providerButton(provider: ModelsDevProvider, registry: ProviderRegistry) -> some View {
        Menu {
            modelSubmenu(for: provider, registry: registry)
        } label: {
            Label(provider.name, systemImage: iconName(for: provider.id))
        }
    }

    @ViewBuilder
    private func modelSubmenu(for provider: ModelsDevProvider, registry: ProviderRegistry) -> some View {
        let models = provider.sortedModels
        let grouped = Dictionary(grouping: models) { $0.family ?? "Other" }
        let sortedFamilies = grouped.keys.sorted()

        ForEach(sortedFamilies, id: \.self) { family in
            if let familyModels = grouped[family] {
                Section(family.uppercased()) {
                    ForEach(familyModels.prefix(10), id: \.id) { model in
                        Button {
                            switchModel(to: model.id, provider: provider.id)
                        } label: {
                            HStack {
                                Text(model.name)
                                Spacer()
                                if model.id == currentModelId(for: provider.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.carbonAccent)
                                }
                                if model.isFree {
                                    Text("FREE")
                                        .font(.carbonMono(.caption2, weight: .bold))
                                        .kerning(0.2)
                                        .foregroundStyle(Color.carbonSuccess)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var activeProviderId: String {
        copilotService.providerRegistry?.activeProviderId ?? settingsStore.selectedModel
    }

    private var displayModelName: String {
        let registry = copilotService.providerRegistry
        let modelId = registry?.activeModelId ?? settingsStore.selectedModel
        let providerId = registry?.activeProviderId ?? ""

        if let provider = registry?.modelsDevProviders[providerId],
           let model = provider.models[modelId] {
            return model.name
        }
        return modelId.isEmpty ? "Model" : modelId
    }

    private func currentModelId(for providerId: String) -> String {
        if providerId == activeProviderId {
            return copilotService.providerRegistry?.activeModelId ?? ""
        }
        return UserDefaults.standard.string(forKey: "providerModel-\(providerId)") ?? ""
    }

    private func switchModel(to modelId: String, provider: String) {
        guard let registry = copilotService.providerRegistry else { return }
        registry.activeProviderId = provider
        registry.activeModelId = modelId
        if provider == "github-copilot" {
            settingsStore.selectedModel = modelId
        }
        Haptics.impact(.light)
    }

    private func iconName(for providerId: String) -> String {
        switch providerId {
        case "github-copilot": return "sparkles"
        case "openai-codex": return "brain"
        case "anthropic": return "eye.fill"
        case "openai", "openrouter": return "circle.hexagongrid"
        case "google": return "diamond.fill"
        case "groq": return "bolt.fill"
        case "xai": return "xmark"
        case "deepseek": return "magnifyingglass"
        case "augment": return "arrow.triangle.merge"
        default: return "cpu"
        }
    }

    private func providerColor(for providerId: String) -> Color {
        switch providerId {
        case "github-copilot": return Color(hex: "6E40C9")
        case "openai-codex": return Color(hex: "10A37F")
        case "anthropic": return Color(hex: "D97757")
        case "openai": return Color(hex: "10A37F")
        case "google": return Color(hex: "4285F4")
        case "groq": return Color(hex: "F55036")
        case "xai": return Color(hex: "FFFFFF")
        case "deepseek": return Color(hex: "4D6BFE")
        default: return Color.carbonAccent
        }
    }
}