import Foundation
import Clibgit2

public let libGit2ErrorDomain = "org.libgit2.libgit2"

internal extension NSError {
    convenience init(gitError errorCode: Int32, pointOfFailure: String? = nil) {
        let code = Int(errorCode)
        var userInfo: [String: String] = [:]

        if let message = errorMessage(errorCode) {
            userInfo[NSLocalizedDescriptionKey] = message
        } else {
            userInfo[NSLocalizedDescriptionKey] = "Unknown libgit2 error."
        }

        if let pointOfFailure = pointOfFailure {
            userInfo[NSLocalizedFailureReasonErrorKey] = "\(pointOfFailure) failed."
        }

        self.init(domain: libGit2ErrorDomain, code: code, userInfo: userInfo)
    }
}

private func errorMessage(_ errorCode: Int32) -> String? {
    if let last = git_error_last() {
        return String(validatingUTF8: last.pointee.message)
    } else if UInt32(errorCode) == GIT_ERROR_OS.rawValue {
        return String(validatingUTF8: strerror(errno))
    } else {
        return nil
    }
}
