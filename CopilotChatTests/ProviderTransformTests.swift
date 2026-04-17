import Testing
@testable import CopilotChat

@Suite("ProviderTransform")
struct ProviderTransformTests {

    private func makeModel(
        id: String = "test-model",
        name: String = "Test Model",
        temperature: Bool = true,
        releaseDate: String? = nil,
        context: Int = 128_000,
        showInPicker: Bool = true,
        priority: Int? = nil
    ) -> ModelsDevModel {
        ModelsDevModel(
            id: id,
            name: name,
            reasoning: true,
            attachment: true,
            toolCall: true,
            structuredOutput: false,
            temperature: temperature,
            cost: nil,
            limit: ModelsDevLimit(context: context, output: 16_384, input: nil),
            releaseDate: releaseDate,
            status: nil,
            family: nil,
            knowledge: nil,
            modalities: nil,
            openWeights: nil,
            lastUpdated: nil,
            showInPicker: showInPicker,
            priority: priority,
            isSubscriptonPlan: false
        )
    }

    @Test("Copilot GPT models omit temperature")
    func copilotGPTModelsOmitTemperature() {
        let temperature = ProviderTransform.requestTemperature(
            modelId: "gpt-5-4",
            model: makeModel(),
            providerId: "github-copilot",
            preferred: 0.7
        )

        #expect(temperature == nil)
    }

    @Test("Copilot o-series models omit temperature")
    func copilotOSeriesModelsOmitTemperature() {
        let temperature = ProviderTransform.requestTemperature(
            modelId: "o4-mini",
            model: makeModel(),
            providerId: "github-copilot",
            preferred: 0.7
        )

        #expect(temperature == nil)
    }

    @Test("Direct GPT models keep preferred temperature")
    func directGPTModelsKeepPreferredTemperature() {
        let temperature = ProviderTransform.requestTemperature(
            modelId: "gpt-5-4",
            model: makeModel(),
            providerId: "openai",
            preferred: 0.7
        )

        #expect(temperature == 0.7)
    }

    @Test("Copilot GPT-5.4 models include xhigh effort")
    func copilotGPT54ModelsIncludeXHighEffort() {
        let efforts = ProviderTransform.availableEfforts(
            modelId: "gpt-5-4",
            npm: "@ai-sdk/openai-compatible",
            model: makeModel(releaseDate: "2026-01-01"),
            providerId: "github-copilot"
        )

        #expect(efforts.contains(.minimal))
        #expect(efforts.contains(.xhigh))
    }

    @Test("Provider model sorting hides hidden entries and respects priority")
    func providerSortingUsesPickerVisibilityAndPriority() {
        let provider = ModelsDevProvider(
            id: "openai-codex",
            name: "OpenAI Codex",
            env: [],
            npm: nil,
            api: "https://chatgpt.com/backend-api/codex",
            doc: nil,
            models: [
                "hidden": makeModel(
                    id: "hidden",
                    name: "Hidden",
                    showInPicker: false,
                    priority: 0
                ),
                "slow": makeModel(
                    id: "slow",
                    name: "Slow",
                    priority: 9
                ),
                "fast": makeModel(
                    id: "fast",
                    name: "Fast",
                    priority: 1
                ),
            ]
        )

        #expect(provider.sortedModels.map(\.id) == ["fast", "slow"])
    }

    @MainActor
    @Test("Provider registry picks highest-priority visible model by default")
    func providerRegistryDefaultSelectionUsesPriority() {
        let registry = ProviderRegistry(authManager: AuthManager())
        registry.modelsDevProviders = [
            "test-provider": ModelsDevProvider(
                id: "test-provider",
                name: "Test Provider",
                env: [],
                npm: nil,
                api: nil,
                doc: nil,
                models: [
                    "hidden-default": makeModel(
                        id: "hidden-default",
                        name: "Hidden",
                        showInPicker: false,
                        priority: 0
                    ),
                    "visible-secondary": makeModel(
                        id: "visible-secondary",
                        name: "Visible Secondary",
                        priority: 5
                    ),
                    "visible-primary": makeModel(
                        id: "visible-primary",
                        name: "Visible Primary",
                        priority: 1
                    ),
                ]
            )
        ]

        registry.activeProviderId = "test-provider"

        #expect(registry.activeModelId == "visible-primary")
    }
}
