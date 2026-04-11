import Clibgit2

public struct Remote: Hashable, Sendable {
    public let name: String
    public let URL: String

    public init(_ pointer: OpaquePointer) {
        name = String(validatingUTF8: git_remote_name(pointer)) ?? ""
        URL = String(validatingUTF8: git_remote_url(pointer)) ?? ""
    }
}
