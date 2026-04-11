import Clibgit2

private class CredentialBox {
    let value: Credentials
    init(_ value: Credentials) { self.value = value }
}

public enum Credentials: Sendable {
    case `default`
    case plaintext(username: String, password: String)

    internal func withPayload<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T {
        let box = CredentialBox(self)
        return withExtendedLifetime(box) {
            body(Unmanaged.passUnretained(box).toOpaque())
        }
    }

    internal static func fromPointer(_ pointer: UnsafeMutableRawPointer) -> Credentials {
        Unmanaged<CredentialBox>.fromOpaque(pointer).takeUnretainedValue().value
    }
}

internal func credentialsCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
    url: UnsafePointer<CChar>?,
    username: UnsafePointer<CChar>?,
    _: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return -1 }
    let credential = Credentials.fromPointer(payload)

    let result: Int32
    switch credential {
    case .default:
        result = git_cred_default_new(cred)
    case .plaintext(let username, let password):
        result = git_cred_userpass_plaintext_new(cred, username, password)
    }

    return (result != GIT_OK.rawValue) ? -1 : 0
}
