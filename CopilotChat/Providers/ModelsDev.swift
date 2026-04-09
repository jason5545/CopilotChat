import Foundation

// MARK: - Models.dev API Integration

/// Fetches and caches provider/model metadata from https://models.dev/api.json
/// This gives access to 120+ providers and 2000+ models dynamically.
actor ModelsDev {
    static let shared = ModelsDev()

    private let apiURL = URL(string: "https://models.dev/api.json")!
    private let cacheTTL: TimeInterval = 5 * 60 // 5 minutes
    private var cachedData: [String: ModelsDevProvider]?
    private var lastFetchTime: Date?

    private var cacheFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models-dev-cache.json")
    }

    // MARK: - Public API

    func providers() async -> [String: ModelsDevProvider] {
        if let cached = cachedData, let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < cacheTTL {
            return cached
        }
        return await refresh()
    }

    func provider(id: String) async -> ModelsDevProvider? {
        let all = await providers()
        return all[id]
    }

    func models(for providerId: String) async -> [ModelsDevModel] {
        guard let provider = await provider(id: providerId) else { return [] }
        return provider.sortedModels
    }

    @discardableResult
    func refresh() async -> [String: ModelsDevProvider] {
        // Try network first
        if let fetched = await fetchFromNetwork() {
            cachedData = fetched
            lastFetchTime = Date()
            await saveToDisk(fetched)
            return fetched
        }
        // Fall back to disk cache
        if let diskData = loadFromDisk() {
            cachedData = diskData
            lastFetchTime = Date()
            return diskData
        }
        return [:]
    }

    // MARK: - Network

    private func fetchFromNetwork() async -> [String: ModelsDevProvider]? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("CopilotChat/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            let raw = try JSONDecoder().decode([String: ModelsDevRawProvider].self, from: data)
            return raw.mapValues { $0.toProvider() }
        } catch {
            print("[ModelsDev] Fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Disk Cache

    private func saveToDisk(_ data: [String: ModelsDevProvider]) async {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: cacheFileURL)
        } catch {
            print("[ModelsDev] Cache save error: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() -> [String: ModelsDevProvider]? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
    }
}

// MARK: - Data Models

struct ModelsDevProvider: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let env: [String]
    let npm: String?
    let api: String?
    let doc: String?
    let models: [String: ModelsDevModel]

    var apiFormat: ProviderAPIFormat {
        .from(npm: npm)
    }

    var sortedModels: [ModelsDevModel] {
        models.values.sorted { a, b in
            // Sort by context window desc, then name
            if a.limit.context != b.limit.context {
                return a.limit.context > b.limit.context
            }
            return a.name < b.name
        }
    }

    var requiresAPIKey: Bool { !env.isEmpty }
    var isCodingPlan: Bool { id.contains("coding-plan") }
    var isChinaRegion: Bool { id.contains("-cn") }
}

struct ModelsDevModel: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let reasoning: Bool
    let attachment: Bool
    let toolCall: Bool
    let temperature: Bool
    let cost: ModelsDevCost?
    let limit: ModelsDevLimit
    let releaseDate: String?
    let status: String?
    let experimental: Bool?

    var contextWindow: Int { limit.context }
    var maxOutputTokens: Int { limit.output }
    var isFree: Bool { cost == nil || (cost?.input == 0 && cost?.output == 0) }

    var displayContextWindow: String {
        let tokens = limit.context
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }

    var displayCost: String {
        guard let cost, !isFree else { return "Free" }
        return "$\(String(format: "%.2f", cost.input))/$\(String(format: "%.2f", cost.output)) per 1M"
    }
}

struct ModelsDevCost: Codable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

struct ModelsDevLimit: Codable, Sendable {
    let context: Int
    let output: Int
    let input: Int?
}

// MARK: - Raw API Response (for decoding)

private struct ModelsDevRawProvider: Codable {
    let id: String?
    let name: String
    let env: [String]
    let npm: String?
    let api: String?
    let doc: String?
    let models: [String: ModelsDevRawModel]

    func toProvider() -> ModelsDevProvider {
        let convertedModels = models.compactMapValues { raw -> ModelsDevModel? in
            return raw.toModel()
        }
        return ModelsDevProvider(
            id: id ?? "",
            name: name,
            env: env,
            npm: npm,
            api: api,
            doc: doc,
            models: convertedModels
        )
    }
}

private struct ModelsDevRawModel: Codable {
    let id: String
    let name: String
    let reasoning: Bool?
    let attachment: Bool?
    let toolCall: Bool?
    let temperature: Bool?
    let cost: ModelsDevCost?
    let limit: ModelsDevRawLimit?
    let releaseDate: String?
    let status: String?
    let experimental: Bool?

    struct ModelsDevRawLimit: Codable {
        let context: Int?
        let output: Int?
        let input: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, reasoning, attachment, temperature, cost, limit, status, experimental
        case toolCall = "tool_call"
        case releaseDate = "release_date"
    }

    func toModel() -> ModelsDevModel? {
        let ctx = limit?.context ?? 0
        let out = limit?.output ?? 4096
        guard ctx > 0 else { return nil }

        return ModelsDevModel(
            id: id,
            name: name,
            reasoning: reasoning ?? false,
            attachment: attachment ?? false,
            toolCall: toolCall ?? false,
            temperature: temperature ?? true,
            cost: cost,
            limit: ModelsDevLimit(context: ctx, output: out, input: limit?.input),
            releaseDate: releaseDate,
            status: status,
            experimental: experimental
        )
    }
}
