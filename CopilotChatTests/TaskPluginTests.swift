import Testing
@testable import CopilotChat

@Suite("TaskPlugin")
struct TaskPluginTests {

    @MainActor
    private func makePlugin() -> (TaskPlugin, SettingsStore, ProviderRegistry) {
        let auth = AuthManager()
        let settings = SettingsStore()
        let registry = ProviderRegistry(authManager: auth)
        let plugin = TaskPlugin(
            authManager: auth,
            settingsStore: settings,
            providerRegistry: registry
        )
        return (plugin, settings, registry)
    }

    private func makeModel(
        id: String,
        name: String,
        reasoning: Bool = false,
        temperature: Bool = true
    ) -> ModelsDevModel {
        ModelsDevModel(
            id: id,
            name: name,
            reasoning: reasoning,
            attachment: false,
            toolCall: true,
            structuredOutput: false,
            temperature: temperature,
            cost: nil,
            limit: .init(context: 128_000, output: 16_000, input: nil),
            releaseDate: nil,
            status: nil,
            family: nil,
            knowledge: nil,
            modalities: nil,
            openWeights: nil,
            lastUpdated: nil,
            isSubscriptonPlan: false
        )
    }

    @Test("New subagent sessions include the initial user prompt")
    @MainActor
    func newSubagentSessionIncludesPrompt() {
        let (plugin, _, _) = makePlugin()

        let session = plugin.makeInitialSubagentSession(
            definition: SubagentRegistry.general,
            prompt: "Investigate the failing ZAI subagent request"
        )

        #expect(session.messages.count == 1)
        #expect(session.messages[0].role == "user")
        #expect(session.messages[0].content == "Investigate the failing ZAI subagent request")
    }

    @Test("Subagent options reuse ZAI provider transforms")
    @MainActor
    func subagentOptionsApplyZAITransforms() {
        let (plugin, settings, registry) = makePlugin()
        settings.reasoningEffort = .high

        let model = makeModel(id: "glm-4.6", name: "GLM-4.6")

        registry.modelsDevProviders["zai"] = ModelsDevProvider(
            id: "zai",
            name: "Z.AI",
            env: ["ZAI_API_KEY"],
            npm: "@ai-sdk/openai-compatible",
            api: "https://api.z.ai/api/coding/v1",
            doc: nil,
            models: ["glm-4.6": model]
        )
        registry.activeProviderId = "zai"
        registry.activeModelId = "glm-4.6"

        let options = plugin.buildSubagentOptions(
            definition: SubagentRegistry.general,
            model: "glm-4.6",
            systemPrompt: "system"
        )

        let thinking = options.extraFields?["thinking"]?.value as? [String: Any]

        #expect(options.temperature == 1.0)
        #expect(options.toolChoice == "auto")
        #expect(options.agentInitiated)
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["clear_thinking"] as? Bool == false)
    }

    @Test("Subagent options reuse Alibaba reasoning transforms")
    @MainActor
    func subagentOptionsApplyAlibabaTransforms() {
        let (plugin, settings, registry) = makePlugin()
        settings.reasoningEffort = .high

        let model = makeModel(
            id: "qwen-reasoning",
            name: "Qwen Reasoning",
            reasoning: true
        )

        registry.modelsDevProviders["alibaba"] = ModelsDevProvider(
            id: "alibaba",
            name: "Alibaba",
            env: ["DASHSCOPE_API_KEY"],
            npm: "@ai-sdk/openai-compatible",
            api: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            doc: nil,
            models: ["qwen-reasoning": model]
        )
        registry.activeProviderId = "alibaba"
        registry.activeModelId = "qwen-reasoning"

        let options = plugin.buildSubagentOptions(
            definition: SubagentRegistry.general,
            model: "qwen-reasoning",
            systemPrompt: "system"
        )

        #expect(options.reasoningEffort == "high")
        #expect(options.extraFields?["enable_thinking"]?.value as? Bool == true)
    }

    @Test("Subagent options reuse GPT-5 extra request fields")
    @MainActor
    func subagentOptionsApplyGPT5Transforms() {
        let (plugin, settings, registry) = makePlugin()
        settings.reasoningEffort = .high

        let model = makeModel(
            id: "gpt-5",
            name: "GPT-5",
            reasoning: true
        )

        registry.modelsDevProviders["openai"] = ModelsDevProvider(
            id: "openai",
            name: "OpenAI",
            env: ["OPENAI_API_KEY"],
            npm: "@ai-sdk/openai-compatible",
            api: "https://api.openai.com/v1",
            doc: nil,
            models: ["gpt-5": model]
        )
        registry.activeProviderId = "openai"
        registry.activeModelId = "gpt-5"

        let options = plugin.buildSubagentOptions(
            definition: SubagentRegistry.general,
            model: "gpt-5",
            systemPrompt: "system"
        )

        let include = options.extraFields?["include"]?.value as? [Any]

        #expect(options.reasoningEffort == "high")
        #expect(options.extraFields?["reasoningSummary"]?.value as? String == "auto")
        #expect(include?.contains(where: { ($0 as? String) == "reasoning.encrypted_content" }) == true)
    }
}
