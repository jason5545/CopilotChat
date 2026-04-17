import Testing
@testable import CopilotChat

@Suite("ProviderTransform")
struct ProviderTransformTests {

    private func makeModel(
        temperature: Bool = true,
        releaseDate: String? = nil
    ) -> ModelsDevModel {
        ModelsDevModel(
            id: "test-model",
            name: "Test Model",
            reasoning: true,
            attachment: true,
            toolCall: true,
            structuredOutput: false,
            temperature: temperature,
            cost: nil,
            limit: ModelsDevLimit(context: 128_000, output: 16_384, input: nil),
            releaseDate: releaseDate,
            status: nil,
            family: nil,
            knowledge: nil,
            modalities: nil,
            openWeights: nil,
            lastUpdated: nil,
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
}
