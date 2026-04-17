import Foundation

// MARK: - Provider Transform

/// Model-specific parameter adjustments, ported from OpenCode's transform.ts.
/// Handles temperature, topP, topK, reasoning effort, max output tokens,
/// and provider-specific extra fields (thinking, thinkingConfig, etc.)
enum ProviderTransform {
    static let outputTokenMax = 32_000

    // MARK: - Max Output Tokens

    /// `min(model.limit.output, 32_000)` — matches OpenCode TS behavior.
    static func maxOutputTokens(model: ModelsDevModel?, modelId: String) -> Int {
        if let model {
            return min(model.maxOutputTokens, outputTokenMax)
        }
        return outputTokenMax
    }

    // MARK: - Temperature

    static func temperature(modelId: String) -> Double? {
        let id = modelId.lowercased()
        if id.contains("qwen") { return 0.55 }
        if id.contains("claude") { return nil }
        if id.contains("gemini") { return 1.0 }
        if id.contains("glm-4.6") || id.contains("glm-4.7") { return 1.0 }
        if id.contains("minimax-m2") { return 1.0 }
        if id.contains("kimi-k2") {
            if ["thinking", "k2.", "k2p", "k2-5"].contains(where: { id.contains($0) }) {
                return 1.0
            }
            return 0.6
        }
        return nil
    }

    /// Resolve the temperature value to send for a request.
    /// Returns nil when the model or provider should omit temperature entirely.
    static func requestTemperature(
        modelId: String,
        model: ModelsDevModel?,
        providerId: String? = nil,
        preferred: Double?
    ) -> Double? {
        if let transformed = temperature(modelId: modelId) {
            return transformed
        }
        // Copilot GPT/o models reject temperature even though models.dev reports support.
        if providerId == "github-copilot" && SSEParser.useResponsesAPI(model: modelId) {
            return nil
        }
        guard model?.temperature == true else { return nil }
        return preferred
    }

    // MARK: - Top P

    static func topP(modelId: String) -> Double? {
        let id = modelId.lowercased()
        if id.contains("qwen") { return 1 }
        if ["minimax-m2", "gemini", "kimi-k2.5", "kimi-k2p5", "kimi-k2-5"]
            .contains(where: { id.contains($0) }) { return 0.95 }
        return nil
    }

    // MARK: - Top K

    static func topK(modelId: String) -> Int? {
        let id = modelId.lowercased()
        if id.contains("minimax-m2") {
            // M2.x variants use 40, others use 20
            if ["m2.", "m25", "m21"].contains(where: { id.contains($0) }) { return 40 }
            return 20
        }
        if id.contains("gemini") { return 64 }
        return nil
    }

    // MARK: - Reasoning Effort Support

    static func supportsReasoningEffort(
        model: ModelsDevModel?, modelId: String, npm: String?, providerId: String? = nil
    ) -> Bool {
        if providerId == "augment" { return false }
        if let model { return model.reasoning }
        let id = modelId.lowercased()
        if id.contains("claude") { return true }
        if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") { return true }
        if id.contains("gpt-4.1") || id.contains("gpt-5") { return true }
        if id.contains("gemini-2.5") || id.contains("gemini-3") { return true }
        if id.contains("deepseek-r1") { return true }
        return false
    }

    /// Available reasoning effort levels for a given model/provider.
    /// Uses release_date from models.dev when available (matching OpenCode TS behavior).
    /// Note: `.off` is NOT included — the caller prepends it for UI display.
    static func availableEfforts(
        modelId: String, npm: String?, model: ModelsDevModel? = nil, providerId: String? = nil
    ) -> [ReasoningEffort] {
        if providerId == "augment" { return [] }
        let id = modelId.lowercased()
        // ISO 8601 date strings compare lexicographically as date order
        let releaseDate = model?.releaseDate ?? ""

        // Models with built-in reasoning that don't support effort control
        if id.contains("deepseek") || id.contains("minimax") || id.contains("glm") ||
           id.contains("mistral") || id.contains("kimi") || id.contains("qwen") {
            return []
        }
        if id.contains("grok") && !id.contains("grok-3-mini") { return [] }
        if id.contains("grok-3-mini") { return [.low, .high] }

        let npmId = npm ?? ""
        let isCopilot = providerId == "github-copilot"

        let isAdaptive = ["opus-4-6", "opus-4.6", "sonnet-4-6", "sonnet-4.6"]
            .contains(where: { id.contains($0) })
        if npmId.contains("anthropic") {
            if isAdaptive { return [.low, .medium, .high, .max] }
            return [.high, .max]
        }
        if npmId.contains("google") {
            if id.contains("2.5") { return [.high, .max] }
            if id.contains("3.1") { return [.low, .medium, .high] }
            return [.low, .high]
        }
        if isCopilot {
            if id.contains("claude") { return [.low, .medium, .high] }
            if id.contains("gemini") { return [] }
        }

        if npmId.contains("openai") || npmId.isEmpty || isCopilot {
            if id.contains("gpt-5") {
                if id.contains("gpt-5-pro") { return [] }
                var efforts: [ReasoningEffort] = []
                if releaseDate >= "2025-11-13" { efforts.append(.none) }
                if id.contains("gpt-5-") || id == "gpt-5" { efforts.append(.minimal) }
                efforts.append(contentsOf: [.low, .medium, .high])
                if id.contains("codex") {
                    if id.contains("5.2") || id.contains("5.3") || id.contains("5.4") ||
                        id.contains("5-2") || id.contains("5-3") || id.contains("5-4") {
                        efforts.append(.xhigh)
                    }
                } else if releaseDate >= "2025-12-04" || id.contains("5.4") || id.contains("5-4") {
                    efforts.append(.xhigh)
                }
                return efforts
            }
            return [.low, .medium, .high]
        }

        return [.low, .medium, .high]
    }

    // MARK: - Context Window

    static func contextWindow(model: ModelsDevModel?, fallback: Int = 128_000) -> Int {
        model?.contextWindow ?? fallback
    }

    // MARK: - Provider-Specific Extra Fields

    /// Extra fields injected into the Chat Completions request body.
    /// These are provider-specific requirements from OpenCode's `options()` function.
    /// Returns [String: AnyCodable] for encoding into the request as top-level fields.
    static func extraRequestFields(
        modelId: String, model: ModelsDevModel?,
        npm: String?, providerId: String, effort: String?
    ) -> [String: AnyCodable]? {
        var result: [String: AnyCodable] = [:]
        let id = modelId.lowercased()

        // Z.AI / Zhipu (including coding-plan variants) — thinking always enabled
        if (providerId.hasPrefix("zai") || providerId.hasPrefix("zhipuai")) &&
           (npm ?? "").contains("openai-compatible") {
            result["thinking"] = AnyCodable(["type": "enabled", "clear_thinking": false])
        }

        // Alibaba (CN and coding-plan) — DashScope requires enable_thinking for reasoning models
        if providerId.hasPrefix("alibaba") &&
           (model?.reasoning ?? false) && !id.contains("kimi-k2-thinking") {
            result["enable_thinking"] = AnyCodable(true)
        }

        // OpenCode / baseten + GLM-4.6 — chat_template_args
        if providerId == "baseten" ||
           (providerId.hasPrefix("opencode") && ["kimi-k2-thinking", "glm-4.6"].contains(id)) {
            result["chat_template_args"] = AnyCodable(["enable_thinking": true])
        }

        // GPT-5 series — reasoningSummary + include
        if id.contains("gpt-5") && !id.contains("gpt-5-chat") && !id.contains("gpt-5-pro") {
            result["reasoningSummary"] = AnyCodable("auto")
            result["include"] = AnyCodable(["reasoning.encrypted_content"])
        }

        return result.isEmpty ? nil : result
    }

    /// Extra fields for Anthropic Messages API (thinking config).
    /// Returns the `thinking` field value for the Anthropic request body.
    static func anthropicThinkingConfig(
        modelId: String, model: ModelsDevModel?, effort: String?
    ) -> [String: AnyCodable]? {
        let id = modelId.lowercased()

        // Kimi-k2.5 via Anthropic SDK — needs explicit thinking budget
        if id.contains("k2p5") || id.contains("kimi-k2.5") || id.contains("kimi-k2p5") {
            let maxOut = model?.maxOutputTokens ?? 16_000
            let budget = min(16_000, maxOut / 2 - 1)
            return ["type": AnyCodable("enabled"), "budgetTokens": AnyCodable(budget)]
        }

        // Claude 4.6 adaptive thinking
        let isAdaptive = ["opus-4-6", "opus-4.6", "sonnet-4-6", "sonnet-4.6"]
            .contains(where: { id.contains($0) })
        if isAdaptive {
            var config: [String: AnyCodable] = ["type": AnyCodable("adaptive")]
            if let effort { config["effort"] = AnyCodable(effort) }
            return config
        }

        // Other Claude reasoning models — budgetTokens based
        if let effort {
            let maxOut = model?.maxOutputTokens ?? 32_000
            switch effort {
            case "high":
                return ["type": AnyCodable("enabled"),
                        "budgetTokens": AnyCodable(min(16_000, maxOut / 2 - 1))]
            case "max":
                return ["type": AnyCodable("enabled"),
                        "budgetTokens": AnyCodable(min(31_999, maxOut - 1))]
            default:
                return nil
            }
        }

        return nil
    }

    /// Extra fields for Gemini GenerateContent API (thinkingConfig).
    static func geminiThinkingConfig(modelId: String, effort: String?) -> [String: AnyCodable]? {
        let id = modelId.lowercased()

        if id.contains("gemini-2.5") || id.contains("gemini-3") {
            var config: [String: AnyCodable] = ["includeThoughts": AnyCodable(true)]
            if let effort {
                switch effort {
                case "high":
                    config["thinkingBudget"] = AnyCodable(16_000)
                case "max":
                    config["thinkingBudget"] = AnyCodable(24_576)
                default: break
                }
            }
            if id.contains("gemini-3") {
                config["thinkingLevel"] = AnyCodable(effort ?? "high")
            }
            return config
        }

        return nil
    }
}
