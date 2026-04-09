import Foundation
import UIKit

// MARK: - OpenAI Codex Provider

/// Provider for OpenAI Codex access via OAuth (ChatGPT Free/Plus/Pro/Team).
/// Uses device code flow (headless) — same approach as OpenCode's codex plugin.
/// OAuth issuer: https://auth.openai.com
/// API endpoint: https://chatgpt.com/backend-api/codex/responses
struct OpenAICodexProvider: LLMProvider, @unchecked Sendable {
    let id = "openai-codex"
    let displayName = "OpenAI Codex"

    private static let codexEndpoint = "https://chatgpt.com/backend-api/codex/responses"
    private let auth: OpenAICodexAuth

    init(auth: OpenAICodexAuth) {
        self.auth = auth
    }

    // MARK: - LLMProvider

    func streamCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { @Sendable in
                do {
                    let token = try await auth.validAccessToken()

                    // ChatGPT Codex uses OpenAI Responses API format
                    let input = Self.convertToResponsesInput(messages: messages, systemPrompt: options.systemPrompt)
                    let apiTools: [ResponsesAPITool]? = tools?.map { tool in
                        ResponsesAPITool(type: "function", name: tool.function.name,
                                         description: tool.function.description,
                                         parameters: tool.function.parameters?.mapValues { $0 })
                    }
                    let request = ResponsesAPIRequest(
                        model: model, instructions: options.systemPrompt ?? "",
                        input: input, stream: true,
                        maxOutputTokens: options.maxOutputTokens,
                        temperature: options.temperature ?? 0.7,
                        tools: apiTools,
                        toolChoice: apiTools != nil ? (options.toolChoice ?? "auto") : nil
                    )
                    let requestData = try JSONEncoder().encode(request)

                    var urlRequest = URLRequest(url: URL(string: Self.codexEndpoint)!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("opencode/1.0.0", forHTTPHeaderField: "User-Agent")
                    urlRequest.setValue("opencode", forHTTPHeaderField: "originator")
                    if let accountId = await auth.accountId {
                        urlRequest.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
                    }
                    urlRequest.httpBody = requestData

                    let bytes = try await SSEParser.validatedBytes(
                        for: urlRequest, session: SSEParser.urlSession)
                    let stream = SSEParser.parseResponsesStream(bytes: bytes)

                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sendCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) async throws -> ProviderResponse {
        let token = try await auth.validAccessToken()

        let input = Self.convertToResponsesInput(messages: messages, systemPrompt: options.systemPrompt)
        let request = ResponsesAPIRequest(
            model: model, instructions: options.systemPrompt ?? "",
            input: input, stream: false,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature ?? 0.7,
            tools: nil, toolChoice: nil
        )
        let requestData = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: URL(string: Self.codexEndpoint)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("opencode", forHTTPHeaderField: "originator")
        if let accountId = await auth.accountId {
            urlRequest.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        urlRequest.httpBody = requestData

        let (data, response) = try await SSEParser.urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse(statusCode: code, body: body)
        }

        // Parse Responses API non-streaming response
        let decoded = try JSONDecoder().decode(NonStreamingResponsesResponse.self, from: data)
        let text = decoded.output.first?.content?.first(where: { $0.type == "output_text" })?.text
        return ProviderResponse(content: text, usage: decoded.usage?.asTokenUsage)
    }

    private static func convertToResponsesInput(
        messages: [APIMessage], systemPrompt: String?
    ) -> [ResponsesInputItem] {
        SSEParser.convertToResponsesInput(messages: messages)
    }
}

// MARK: - OpenAI Codex OAuth (Device Code Flow)

/// Handles OpenAI OAuth for Codex access (ChatGPT Free/Plus/Pro/Team).
/// Uses device code flow — similar to GitHub Copilot's device flow in AuthManager.
///
/// Flow:
/// 1. POST to /api/accounts/deviceauth/usercode → get device_auth_id + user_code
/// 2. User visits https://auth.openai.com/codex/device and enters the code
/// 3. App polls /api/accounts/deviceauth/token until authorized
/// 4. Exchange authorization_code for access_token + refresh_token
/// 5. Store tokens in Keychain, auto-refresh when expired
@Observable
@MainActor
final class OpenAICodexAuth {
    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let keychainRefreshKey = "chatgpt-refresh-token"
    private static let keychainAccessKey = "chatgpt-access-token"
    private static let keychainExpiresKey = "chatgpt-token-expires"
    private static let keychainAccountIdKey = "chatgpt-account-id"

    var isAuthenticated = false
    var isAuthenticating = false
    var authError: String?

    /// Device code for user to enter at auth.openai.com/codex/device
    var deviceUserCode: String?
    var deviceVerificationURL: String?

    /// Account ID from JWT claims (for ChatGPT-Account-Id header)
    private(set) var accountId: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpires: Date?

    init() {
        loadSavedTokens()
    }

    // MARK: - Token Management

    /// Get a valid access token, refreshing if expired.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expires = tokenExpires, expires > Date() {
            return token
        }
        // Try refresh
        guard let refresh = refreshToken else {
            throw ProviderError.noAPIKey
        }
        try await refreshAccessToken(refresh)
        guard let token = accessToken else {
            throw ProviderError.authenticationFailed
        }
        return token
    }

    // MARK: - Device Code Flow

    func startDeviceFlow() async {
        isAuthenticating = true
        authError = nil
        deviceUserCode = nil

        do {
            // Step 1: Request device code
            let deviceData = try await requestDeviceCode()
            deviceUserCode = deviceData.userCode
            deviceVerificationURL = "\(Self.issuer)/codex/device"

            // Step 2: Auto-copy code to clipboard and open browser
            UIPasteboard.general.string = deviceData.userCode
            if let url = URL(string: "\(Self.issuer)/codex/device") {
                await UIApplication.shared.open(url)
            }

            // Step 3: Poll for authorization
            let interval = max(Int(deviceData.interval) ?? 5, 1)
            let tokens = try await pollForAuthorization(
                deviceAuthId: deviceData.deviceAuthId,
                userCode: deviceData.userCode,
                interval: interval
            )

            // Step 3: Exchange for access token
            let tokenResponse = try await exchangeAuthCode(
                code: tokens.authorizationCode,
                codeVerifier: tokens.codeVerifier
            )

            // Step 4: Extract account ID from JWT
            accountId = Self.extractAccountId(from: tokenResponse.accessToken)
                ?? Self.extractAccountId(from: tokenResponse.idToken ?? "")

            // Step 5: Save tokens
            accessToken = tokenResponse.accessToken
            refreshToken = tokenResponse.refreshToken
            let expiresIn = tokenResponse.expiresIn ?? 3600
            tokenExpires = Date().addingTimeInterval(TimeInterval(expiresIn))

            saveTokens()
            isAuthenticated = true
            deviceUserCode = nil
        } catch {
            authError = error.localizedDescription
        }

        isAuthenticating = false
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpires = nil
        accountId = nil
        isAuthenticated = false
        deviceUserCode = nil
        KeychainHelper.delete(key: Self.keychainRefreshKey)
        KeychainHelper.delete(key: Self.keychainAccessKey)
        KeychainHelper.delete(key: Self.keychainExpiresKey)
        KeychainHelper.delete(key: Self.keychainAccountIdKey)
    }

    // MARK: - API Calls

    private struct DeviceCodeResponse {
        let deviceAuthId: String
        let userCode: String
        let interval: String
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/api/accounts/deviceauth/usercode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("opencode/1.0.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(["client_id": Self.clientID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.authenticationFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return DeviceCodeResponse(
            deviceAuthId: json["device_auth_id"] as? String ?? "",
            userCode: json["user_code"] as? String ?? "",
            interval: json["interval"] as? String ?? "5"
        )
    }

    private struct AuthorizationResult {
        let authorizationCode: String
        let codeVerifier: String
    }

    private func pollForAuthorization(
        deviceAuthId: String, userCode: String, interval: Int
    ) async throws -> AuthorizationResult {
        let pollInterval = TimeInterval(interval) + 3 // safety margin
        let timeout = Date().addingTimeInterval(5 * 60) // 5 minute timeout

        while Date() < timeout {
            try await Task.sleep(for: .seconds(pollInterval))
            try Task.checkCancellation()

            var request = URLRequest(url: URL(string: "\(Self.issuer)/api/accounts/deviceauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("opencode/1.0.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode([
                "device_auth_id": deviceAuthId,
                "user_code": userCode
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }

            if http.statusCode == 200 {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                return AuthorizationResult(
                    authorizationCode: json["authorization_code"] as? String ?? "",
                    codeVerifier: json["code_verifier"] as? String ?? ""
                )
            }

            // 403/404 = still pending, keep polling
            if http.statusCode != 403 && http.statusCode != 404 {
                throw ProviderError.authenticationFailed
            }
        }

        throw ProviderError.authenticationFailed
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let idToken: String?
        let expiresIn: Int?
    }

    private func exchangeAuthCode(code: String, codeVerifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "\(Self.issuer)/deviceauth/callback",
            "client_id": Self.clientID,
            "code_verifier": codeVerifier
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
         .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.authenticationFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return TokenResponse(
            accessToken: json["access_token"] as? String ?? "",
            refreshToken: json["refresh_token"] as? String ?? "",
            idToken: json["id_token"] as? String,
            expiresIn: json["expires_in"] as? Int
        )
    }

    private func refreshAccessToken(_ refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
         .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Refresh failed — need to re-authenticate
            signOut()
            throw ProviderError.authenticationFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.accessToken = json["access_token"] as? String
        self.refreshToken = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? Int ?? 3600
        self.tokenExpires = Date().addingTimeInterval(TimeInterval(expiresIn))

        // Update account ID if available
        if let newAccessToken = self.accessToken {
            self.accountId = Self.extractAccountId(from: newAccessToken) ?? self.accountId
        }

        saveTokens()
    }

    // MARK: - JWT Parsing

    private static func extractAccountId(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let data = Data(base64Encoded: Self.base64Pad(String(parts[1]))),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Check multiple possible locations for account ID
        if let id = claims["chatgpt_account_id"] as? String { return id }
        if let authClaim = claims["https://api.openai.com/auth"] as? [String: Any],
           let id = authClaim["chatgpt_account_id"] as? String { return id }
        if let orgs = claims["organizations"] as? [[String: Any]],
           let id = orgs.first?["id"] as? String { return id }
        return nil
    }

    private static func base64Pad(_ string: String) -> String {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return s
    }

    // MARK: - Keychain Persistence

    private func saveTokens() {
        if let refresh = refreshToken { KeychainHelper.save(refresh, for: Self.keychainRefreshKey) }
        if let access = accessToken { KeychainHelper.save(access, for: Self.keychainAccessKey) }
        if let expires = tokenExpires {
            KeychainHelper.save(String(expires.timeIntervalSince1970), for: Self.keychainExpiresKey)
        }
        if let accountId { KeychainHelper.save(accountId, for: Self.keychainAccountIdKey) }
    }

    private func loadSavedTokens() {
        refreshToken = KeychainHelper.loadString(key: Self.keychainRefreshKey)
        accessToken = KeychainHelper.loadString(key: Self.keychainAccessKey)
        accountId = KeychainHelper.loadString(key: Self.keychainAccountIdKey)
        if let expiresStr = KeychainHelper.loadString(key: Self.keychainExpiresKey),
           let interval = TimeInterval(expiresStr) {
            tokenExpires = Date(timeIntervalSince1970: interval)
        }
        isAuthenticated = refreshToken != nil
    }
}
