import Foundation
import Observation

@Observable
@MainActor
final class AuthManager {
    // App OAuth client ID
    static let clientID = "Ov23li8tweQw6odWQebz"
    static let scope = "read:user,repo"
    static let keychainKey = "github_token"
    static let legacyKeychainKey = "github_token_vscode"
    static let userAgent = "GitHubCopilotChat/0.26.7"
    // Bump when GitHub OAuth scopes or app identity change so stale tokens get discarded.
    private static let authConfigVersion = 2
    private static let authConfigVersionKey = "github_auth_config_version"

    var isAuthenticated = false
    var username: String?
    var avatarUrl: String?
    var isAuthenticating = false
    var deviceFlowUserCode: String?
    var deviceFlowVerificationURL: String?
    var authError: String?

    private var githubToken: String?
    var token: String? { githubToken }

    /// Dedicated session for OAuth polling — survives app backgrounding.
    private static let authSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 900  // match device code expiry (~15 min)
        return URLSession(configuration: config)
    }()

    init() {
        invalidateStoredTokenIfNeeded()
        // The old token was minted under a different OAuth app identity, so force re-auth.
        KeychainHelper.delete(key: Self.legacyKeychainKey)
        loadSavedToken()
    }

    // MARK: - Token Management

    private func invalidateStoredTokenIfNeeded() {
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: Self.authConfigVersionKey)
        guard storedVersion != Self.authConfigVersion else { return }

        KeychainHelper.delete(key: Self.keychainKey)
        KeychainHelper.delete(key: Self.legacyKeychainKey)
        defaults.set(Self.authConfigVersion, forKey: Self.authConfigVersionKey)
    }

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
        KeychainHelper.delete(key: Self.legacyKeychainKey)
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

            // Auto-copy code to clipboard and open browser
            PlatformHelpers.copyToClipboard(deviceCode.userCode)
            if let url = URL(string: deviceCode.verificationUri) {
                await PlatformHelpers.openURL(url)
            }

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
        let maxRetries = 3

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

            // Retry on transient network errors (e.g. connection lost after iOS backgrounding)
            var data = Data()
            var succeeded = false
            for attempt in 0..<maxRetries {
                do {
                    let (responseData, _) = try await Self.authSession.data(for: request)
                    data = responseData
                    succeeded = true
                    break
                } catch let error as URLError where Self.isTransientError(error) {
                    if attempt == maxRetries - 1 { throw error }
                    try await Task.sleep(for: .seconds(2))
                    try Task.checkCancellation()
                }
            }
            guard succeeded else { continue }

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

    /// Transient network errors that should be retried (common after iOS app backgrounding).
    private static func isTransientError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,      // -1005: the exact error we're fixing
             .notConnectedToInternet,      // -1009: device still reconnecting
             .timedOut,                    // -1001: stale connection timeout
             .cannotConnectToHost,         // -1004: server unreachable briefly
             .dnsLookupFailed,            // -1006: DNS cache stale after wake
             .secureConnectionFailed:      // -1200: TLS renegotiation after resume
            return true
        default:
            return false
        }
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
