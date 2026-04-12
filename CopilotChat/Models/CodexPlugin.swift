import Foundation

@MainActor
final class CodexPlugin: Plugin, @unchecked Sendable {
    let id = "com.copilotchat.codex"
    let name = "OpenAI Codex"
    let version = "1.0.0"

    let auth = OpenAICodexAuth()

    func configure(with input: PluginInput) async throws -> PluginHooks {
        let authRef = auth
        let authHook = AuthHook(
            providerId: "openai-codex",
            isAuthenticated: { [weak authRef] in authRef?.isAuthenticated ?? false },
            isAuthenticating: { [weak authRef] in authRef?.isAuthenticating ?? false },
            authError: { [weak authRef] in authRef?.authError },
            deviceUserCode: { [weak authRef] in authRef?.deviceUserCode },
            startDeviceFlow: { [weak authRef] in await authRef?.startDeviceFlow() },
            signOut: { [weak authRef] in authRef?.signOut() },
            validAccessToken: { [weak authRef] in
                guard let authRef else { throw ProviderError.noAPIKey }
                return try await authRef.validAccessToken()
            },
            accountId: { [weak authRef] in authRef?.accountId }
        )
        return PluginHooks(tools: [], auth: authHook)
    }
}
