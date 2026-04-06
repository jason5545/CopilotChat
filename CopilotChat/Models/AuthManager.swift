import Foundation
import Observation

@Observable
@MainActor
final class AuthManager {
    // OpenCode's Copilot OAuth Client ID
    static let clientID = "Ov23li8tweQw6odWQebz"
    static let scope = "read:user"
    static let keychainKey = "github_token"
    static let userAgent = "CopilotChat/1.0.0"

    var isAuthenticated = false
    var username: String?
    var avatarUrl: String?
    var isAuthenticating = false
    var deviceFlowUserCode: String?
    var deviceFlowVerificationURL: String?
    var authError: String?

    private var githubToken: String?

    var token: String? { githubToken }

    init() {
        loadSavedToken()
    }

    // MARK: - Token Management

    private func loadSavedToken() {
        if let saved = KeychainHelper.loadString(key: Self.keychainKey) {
            githubToken = saved
            isAuthenticated = true
            Task { await fetchUserInfo() }
        }
    }

    private func saveToken(_ token: String) {
        githubToken = token
        KeychainHelper.save(token, for: Self.keychainKey)
        isAuthenticated = true
    }

    func signOut() {
        githubToken = nil
        username = nil
        avatarUrl = nil
        isAuthenticated = false
        KeychainHelper.delete(key: Self.keychainKey)
    }

    // MARK: - Device Flow OAuth

    func startDeviceFlow() async {
        isAuthenticating = true
        authError = nil
        deviceFlowUserCode = nil
        deviceFlowVerificationURL = nil

        do {
            let deviceCode = try await requestDeviceCode()
            deviceFlowUserCode = deviceCode.userCode
            deviceFlowVerificationURL = deviceCode.verificationUri

            let token = try await pollForAccessToken(deviceCode: deviceCode)
            saveToken(token)
            await fetchUserInfo()
        } catch is CancellationError {
            // User cancelled
        } catch {
            authError = error.localizedDescription
        }

        isAuthenticating = false
        deviceFlowUserCode = nil
        deviceFlowVerificationURL = nil
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: String] = [
            "client_id": Self.clientID,
            "scope": Self.scope,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.deviceCodeRequestFailed
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollForAccessToken(deviceCode: DeviceCodeResponse) async throws -> String {
        var interval = TimeInterval(deviceCode.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval + 3))
            try Task.checkCancellation()

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let body: [String: String] = [
                "client_id": Self.clientID,
                "device_code": deviceCode.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            request.httpBody = try JSONEncoder().encode(body)

            let (data, _) = try await URLSession.shared.data(for: request)
            let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

            if let token = tokenResponse.accessToken {
                return token
            }

            switch tokenResponse.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            case "expired_token":
                throw AuthError.deviceCodeExpired
            case "access_denied":
                throw AuthError.accessDenied
            default:
                if let error = tokenResponse.error {
                    throw AuthError.unknown(error)
                }
                continue
            }
        }

        throw AuthError.deviceCodeExpired
    }

    // MARK: - User Info

    private func fetchUserInfo() async {
        guard let token = githubToken else { return }

        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let user = try JSONDecoder().decode(GitHubUser.self, from: data)
            username = user.login
            avatarUrl = user.avatarUrl
        } catch {
            // Non-critical, just don't show username
        }
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case deviceCodeRequestFailed
        case deviceCodeExpired
        case accessDenied
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .deviceCodeRequestFailed: "Failed to request device code"
            case .deviceCodeExpired: "Device code expired. Please try again."
            case .accessDenied: "Access denied. Please try again."
            case .unknown(let msg): "Authentication error: \(msg)"
            }
        }
    }
}
