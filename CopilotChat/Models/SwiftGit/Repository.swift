import Foundation
import Clibgit2

public typealias CheckoutProgressBlock = (String?, Int, Int) -> Void

private func checkoutProgressCallback(
    path: UnsafePointer<Int8>?,
    completedSteps: Int,
    totalSteps: Int,
    payload: UnsafeMutableRawPointer?
) {
    guard let payload else { return }
    let buffer = payload.assumingMemoryBound(to: CheckoutProgressBlock.self)
    let isLast = completedSteps >= totalSteps
    let block: CheckoutProgressBlock = isLast ? buffer.move() : buffer.pointee
    if isLast {
        buffer.deallocate()
    }
    block(path.flatMap { String(validatingUTF8: $0) }, completedSteps, totalSteps)
}

private func checkoutOptions(
    strategy: CheckoutStrategy,
    progress: CheckoutProgressBlock? = nil
) -> git_checkout_options {
    var options = git_checkout_options()
    git_checkout_init_options(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))

    options.checkout_strategy = strategy.gitCheckoutStrategy.rawValue

    if let progress {
        options.progress_cb = checkoutProgressCallback
        let blockPointer = UnsafeMutablePointer<CheckoutProgressBlock>.allocate(capacity: 1)
        blockPointer.initialize(to: progress)
        options.progress_payload = UnsafeMutableRawPointer(blockPointer)
    }

    return options
}

private func withFetchOptions<T>(credentials: Credentials, _ body: (inout git_fetch_options) -> T) -> T {
    credentials.withPayload { payload in
        var options = git_fetch_options()
        git_fetch_init_options(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))

        options.callbacks.payload = payload
        options.callbacks.credentials = credentialsCallback

        return body(&options)
    }
}

private func cloneOptions(
    bare: Bool = false,
    localClone: Bool = false,
    fetchOptions: git_fetch_options? = nil,
    checkoutOptions: git_checkout_options? = nil
) -> git_clone_options {
    var options = git_clone_options()
    git_clone_init_options(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))

    options.bare = bare ? 1 : 0

    if localClone {
        options.local = GIT_CLONE_NO_LOCAL
    }

    if let checkoutOptions {
        options.checkout_opts = checkoutOptions
    }

    if let fetchOptions {
        options.fetch_opts = fetchOptions
    }

    return options
}

/// A git repository.
public final class Repository: @unchecked Sendable {

    private static let gitInit: Void = { _ = git_libgit2_init() }()

    // MARK: - Creating Repositories

    /// Create a new repository at the given URL.
    ///
    /// URL - The URL of the repository.
    ///
    /// Returns a `Result` with a `Repository` or an error.
    public class func create(at url: URL) -> Result<Repository, NSError> {
        _ = Self.gitInit
        var pointer: OpaquePointer?
        let result = url.withUnsafeFileSystemRepresentation {
            git_repository_init(&pointer, $0, 0)
        }

        guard result == GIT_OK.rawValue, let pointer else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_init"))
        }

        return .success(Repository(pointer))
    }

    /// Load the repository at the given URL.
    ///
    /// URL - The URL of the repository.
    ///
    /// Returns a `Result` with a `Repository` or an error.
    public class func at(_ url: URL) -> Result<Repository, NSError> {
        _ = Self.gitInit
        var pointer: OpaquePointer?
        let result = url.withUnsafeFileSystemRepresentation {
            git_repository_open(&pointer, $0)
        }

        guard result == GIT_OK.rawValue, let pointer else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_open"))
        }

        return .success(Repository(pointer))
    }

    /// Clone the repository from a given URL.
    ///
    /// remoteURL        - The URL of the remote repository
    /// localURL         - The URL to clone the remote repository into
    /// localClone       - Will not bypass the git-aware transport, even if remote is local.
    /// bare             - Clone remote as a bare repository.
    /// credentials      - Credentials to be used when connecting to the remote.
    /// checkoutStrategy - The checkout strategy to use, if being checked out.
    /// checkoutProgress - A block that's called with the progress of the checkout.
    ///
    /// Returns a `Result` with a `Repository` or an error.
    public class func clone(
        from remoteURL: URL,
        to localURL: URL,
        localClone: Bool = false,
        bare: Bool = false,
        depth: Int = 0,
        credentials: Credentials = .default,
        checkoutStrategy: CheckoutStrategy = .Safe,
        checkoutProgress: CheckoutProgressBlock? = nil
    ) -> Result<Repository, NSError> {
        _ = Self.gitInit
        return withFetchOptions(credentials: credentials) { fetchOptions in
            var mutFetch = fetchOptions
            if depth > 0 {
                mutFetch.depth = Int32(depth)
            }
            var options = cloneOptions(
                bare: bare,
                localClone: localClone,
                fetchOptions: mutFetch,
                checkoutOptions: checkoutOptions(strategy: checkoutStrategy, progress: checkoutProgress))

            var pointer: OpaquePointer?
            let remoteURLString = (remoteURL as NSURL).isFileReferenceURL()
                ? remoteURL.path
                : remoteURL.absoluteString
            let result = localURL.withUnsafeFileSystemRepresentation { localPath in
                git_clone(&pointer, remoteURLString, localPath, &options)
            }

            guard result == GIT_OK.rawValue, let pointer else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_clone"))
            }

            return .success(Repository(pointer))
        }
    }

    // MARK: - Initializers

    /// Create an instance with a libgit2 `git_repository` object.
    ///
    /// The Repository assumes ownership of the `git_repository` object.
    public init(_ pointer: OpaquePointer) {
        self.pointer = pointer

        let path = git_repository_workdir(pointer)
        self.directoryURL = path.flatMap {
            guard let str = String(validatingUTF8: $0) else { return nil }
            return URL(fileURLWithPath: str, isDirectory: true)
        }
    }

    deinit {
        git_repository_free(pointer)
    }

    // MARK: - Properties

    /// The underlying libgit2 `git_repository` object.
    public let pointer: OpaquePointer

    /// The URL of the repository's working directory, or `nil` if the
    /// repository is bare.
    public let directoryURL: URL?

    // MARK: - Push

    /// Push to the "origin" remote using the given credentials.
    ///
    /// credentials - Credentials for authentication.
    /// branch      - The branch name to push. If nil, uses "main" or the first local branch.
    ///
    /// Returns a `Result` with void or an error.
    public func push(
        credentials: Credentials = .default,
        branch: String? = nil
    ) -> Result<(), NSError> {
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, pointer, "origin")
        guard lookupResult == GIT_OK.rawValue, let remote else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_remote_lookup"))
        }
        defer { git_remote_free(remote) }

        var refSpec: String
        if let branch {
            let fullRef = "refs/heads/" + branch
            if case .success = reference(named: fullRef) {
                refSpec = fullRef
            } else {
                var headOid = git_oid()
                let nameToIdResult = git_reference_name_to_id(&headOid, pointer, "HEAD")
                guard nameToIdResult == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: nameToIdResult, pointOfFailure: "git_reference_name_to_id"))
                }
                var headCommit: OpaquePointer?
                let lookupRC = git_commit_lookup(&headCommit, pointer, &headOid)
                guard lookupRC == GIT_OK.rawValue, let headCommit else {
                    return .failure(NSError(gitError: lookupRC, pointOfFailure: "git_commit_lookup"))
                }

                var gitBranch: OpaquePointer?
                let createResult = git_branch_create(&gitBranch, pointer, branch, headCommit, 1)
                git_commit_free(headCommit)
                if let gitBranch { git_reference_free(gitBranch) }
                guard createResult == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: createResult, pointOfFailure: "git_branch_create"))
                }
                refSpec = fullRef
            }
        } else {
            if case .success = reference(named: "refs/heads/main") {
                refSpec = "refs/heads/main"
            } else {
                switch localBranches() {
                case .success(let branches):
                    guard let first = branches.first else {
                        return .failure(NSError(
                            domain: libGit2ErrorDomain,
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No local branches found."]
                        ))
                    }
                    refSpec = first.longName
                case .failure(let error):
                    return .failure(error)
                }
            }
        }

        guard let refSpecCStr = strdup(refSpec) else {
            return .failure(NSError(
                domain: libGit2ErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate refspec string."]
            ))
        }
        defer { free(refSpecCStr) }

        var cStrings: [UnsafeMutablePointer<CChar>?] = [refSpecCStr, nil]

        return credentials.withPayload { payload in
            var options = git_push_options()
            let initResult = git_push_init_options(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
            guard initResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: initResult, pointOfFailure: "git_push_init_options"))
            }
            options.callbacks.payload = payload
            options.callbacks.credentials = credentialsCallback

            return cStrings.withUnsafeMutableBufferPointer { buffer in
                var gitStrArray = git_strarray()
                gitStrArray.strings = buffer.baseAddress
                gitStrArray.count = 1

                let pushResult = git_remote_push(remote, &gitStrArray, &options)
                guard pushResult == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: pushResult, pointOfFailure: "git_remote_push"))
                }
                return .success(())
            }
        }
    }

    // MARK: - Object Lookups

    /// Load a libgit2 object and transform it to something else.
    private func withGitObject<T>(
        _ oid: OID,
        type: git_object_t,
        transform: (OpaquePointer) -> Result<T, NSError>
    ) -> Result<T, NSError> {
        var pointer: OpaquePointer?
        var oid = oid.oid
        let result = git_object_lookup(&pointer, self.pointer, &oid, type)

        guard result == GIT_OK.rawValue, let pointer else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_object_lookup"))
        }

        let value = transform(pointer)
        git_object_free(pointer)
        return value
    }

    private func withGitObject<T>(
        _ oid: OID,
        type: git_object_t,
        transform: (OpaquePointer) -> T
    ) -> Result<T, NSError> {
        return withGitObject(oid, type: type) { .success(transform($0)) }
    }

    private func withGitObjects<T>(
        _ oids: [OID],
        type: git_object_t,
        transform: ([OpaquePointer]) -> Result<T, NSError>
    ) -> Result<T, NSError> {
        var pointers = [OpaquePointer]()
        defer {
            for pointer in pointers {
                git_object_free(pointer)
            }
        }

        for oid in oids {
            var pointer: OpaquePointer?
            var oid = oid.oid
            let result = git_object_lookup(&pointer, self.pointer, &oid, type)

            guard result == GIT_OK.rawValue, let pointer else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_object_lookup"))
            }

            pointers.append(pointer)
        }

        return transform(pointers)
    }

    /// Loads the object with the given OID.
    public func object(_ oid: OID) -> Result<ObjectType, NSError> {
        return withGitObject(oid, type: GIT_OBJECT_ANY) { object in
            let type = git_object_type(object)
            if type == Blob.type {
                return .success(Blob(object))
            } else if type == Commit.type {
                return .success(Commit(object))
            } else if type == Tag.type {
                return .success(Tag(object))
            } else if type == Tree.type {
                return .success(Tree(object))
            }

            let error = NSError(
                domain: "org.libgit2.SwiftGit2",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unrecognized git_object_t '\(type)' for oid '\(oid)'.",
                ]
            )
            return .failure(error)
        }
    }

    /// Loads the blob with the given OID.
    public func blob(_ oid: OID) -> Result<Blob, NSError> {
        return withGitObject(oid, type: GIT_OBJECT_BLOB) { Blob($0) }
    }

    /// Loads the commit with the given OID.
    public func commit(_ oid: OID) -> Result<Commit, NSError> {
        return withGitObject(oid, type: GIT_OBJECT_COMMIT) { Commit($0) }
    }

    /// Loads the tag with the given OID.
    public func tag(_ oid: OID) -> Result<Tag, NSError> {
        return withGitObject(oid, type: GIT_OBJECT_TAG) { Tag($0) }
    }

    /// Loads the tree with the given OID.
    public func tree(_ oid: OID) -> Result<Tree, NSError> {
        return withGitObject(oid, type: GIT_OBJECT_TREE) { Tree($0) }
    }

    /// Loads the referenced object from the pointer.
    public func object<T>(from pointer: PointerTo<T>) -> Result<T, NSError> {
        return withGitObject(pointer.oid, type: pointer.type) { T($0) }
    }

    /// Loads the referenced object from the pointer.
    public func object(from pointer: Pointer) -> Result<ObjectType, NSError> {
        switch pointer {
        case let .blob(oid):
            return blob(oid).map { $0 as ObjectType }
        case let .commit(oid):
            return commit(oid).map { $0 as ObjectType }
        case let .tag(oid):
            return tag(oid).map { $0 as ObjectType }
        case let .tree(oid):
            return tree(oid).map { $0 as ObjectType }
        }
    }

    // MARK: - Remote Lookups

    /// Loads all the remotes in the repository.
    public func allRemotes() -> Result<[Remote], NSError> {
        let pointer = UnsafeMutablePointer<git_strarray>.allocate(capacity: 1)
        let result = git_remote_list(pointer, self.pointer)

        guard result == GIT_OK.rawValue else {
            pointer.deallocate()
            return .failure(NSError(gitError: result, pointOfFailure: "git_remote_list"))
        }

        let strarray = pointer.pointee
        let remotes: [Result<Remote, NSError>] = strarray.map {
            return self.remote(named: $0)
        }
        git_strarray_free(pointer)
        pointer.deallocate()

        return remotes.aggregateResult()
    }

    private func remoteLookup<A>(
        named name: String,
        _ callback: (Result<OpaquePointer, NSError>) -> A
    ) -> A {
        var pointer: OpaquePointer?
        defer { git_remote_free(pointer) }

        let result = git_remote_lookup(&pointer, self.pointer, name)

        guard result == GIT_OK.rawValue, let pointer else {
            return callback(.failure(NSError(gitError: result, pointOfFailure: "git_remote_lookup")))
        }

        return callback(.success(pointer))
    }

    /// Load a remote from the repository.
    public func remote(named name: String) -> Result<Remote, NSError> {
        return remoteLookup(named: name) { $0.map(Remote.init) }
    }

    /// Download new data and update tips
    /// - Parameters:
    ///   - remote: The remote to fetch from
    ///   - refspecs: Optional array of refspecs to fetch. If nil, uses remote's default.
    ///   - credentials: Authentication credentials
    public func fetch(_ remote: Remote, refspecs: [String]? = nil, credentials: Credentials = .default) -> Result<(), NSError> {
        return remoteLookup(named: remote.name) { remote in
            remote.flatMap { pointer in
                return withFetchOptions(credentials: credentials) { opts in
                    let result: Int32
                    if let specs = refspecs, !specs.isEmpty {
                        result = specs.withUnsafeBufferPointer { buffer in
                            var strarray = git_strarray()
                            strarray.strings = buffer.baseAddress
                            strarray.count = Int32(buffer.count)
                            return git_remote_fetch(pointer, &strarray, &opts, nil)
                        }
                    } else {
                        result = git_remote_fetch(pointer, nil, &opts, nil)
                    }
                    guard result == GIT_OK.rawValue else {
                        return .failure(NSError(gitError: result, pointOfFailure: "git_remote_fetch"))
                    }
                    return .success(())
                }
            }
        }
    }

    // MARK: - Reference Lookups

    /// Load all the references with the given prefix (e.g. "refs/heads/")
    public func references(withPrefix prefix: String) -> Result<[ReferenceType], NSError> {
        let pointer = UnsafeMutablePointer<git_strarray>.allocate(capacity: 1)
        let result = git_reference_list(pointer, self.pointer)

        guard result == GIT_OK.rawValue else {
            pointer.deallocate()
            return .failure(NSError(gitError: result, pointOfFailure: "git_reference_list"))
        }

        let strarray = pointer.pointee
        let references = strarray
            .filter { $0.hasPrefix(prefix) }
            .map { self.reference(named: $0) }
        git_strarray_free(pointer)
        pointer.deallocate()

        return references.aggregateResult()
    }

    /// Load the reference with the given long name (e.g. "refs/heads/master")
    public func reference(named name: String) -> Result<ReferenceType, NSError> {
        var pointer: OpaquePointer?
        let result = git_reference_lookup(&pointer, self.pointer, name)

        guard result == GIT_OK.rawValue, let pointer else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_reference_lookup"))
        }

        let value = referenceWithLibGit2Reference(pointer)
        git_reference_free(pointer)
        return .success(value)
    }

    /// Load and return a list of all local branches.
    public func localBranches() -> Result<[Branch], NSError> {
        return references(withPrefix: "refs/heads/")
            .map { refs in
                refs.compactMap { $0 as? Branch }
            }
    }

    /// Load and return a list of all remote branches.
    public func remoteBranches() -> Result<[Branch], NSError> {
        return references(withPrefix: "refs/remotes/")
            .map { refs in
                refs.compactMap { $0 as? Branch }
            }
    }

    /// Load the local branch with the given name (e.g., "master").
    public func localBranch(named name: String) -> Result<Branch, NSError> {
        return reference(named: "refs/heads/" + name).flatMap { ref in
            guard let branch = ref as? Branch else {
                return .failure(NSError(
                    domain: libGit2ErrorDomain,
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Reference '\(name)' is not a branch."]
                ))
            }
            return .success(branch)
        }
    }

    /// Load the remote branch with the given name (e.g., "origin/master").
    public func remoteBranch(named name: String) -> Result<Branch, NSError> {
        return reference(named: "refs/remotes/" + name).flatMap { ref in
            guard let branch = ref as? Branch else {
                return .failure(NSError(
                    domain: libGit2ErrorDomain,
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Reference '\(name)' is not a branch."]
                ))
            }
            return .success(branch)
        }
    }

    /// Load and return a list of all the `TagReference`s.
    public func allTags() -> Result<[TagReference], NSError> {
        return references(withPrefix: "refs/tags/")
            .map { refs in
                refs.compactMap { $0 as? TagReference }
            }
    }

    /// Load the tag with the given name (e.g., "tag-2").
    public func tag(named name: String) -> Result<TagReference, NSError> {
        return reference(named: "refs/tags/" + name).flatMap { ref in
            guard let tagRef = ref as? TagReference else {
                return .failure(NSError(
                    domain: libGit2ErrorDomain,
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Reference '\(name)' is not a tag."]
                ))
            }
            return .success(tagRef)
        }
    }

    // MARK: - Working Directory

    /// Load the reference pointed at by HEAD.
    public func HEAD() -> Result<ReferenceType, NSError> {
        var pointer: OpaquePointer?
        let result = git_repository_head(&pointer, self.pointer)
        guard result == GIT_OK.rawValue, let pointer else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_head"))
        }
        let value = referenceWithLibGit2Reference(pointer)
        git_reference_free(pointer)
        return .success(value)
    }

    /// Set HEAD to the given oid (detached).
    public func setHEAD(_ oid: OID) -> Result<(), NSError> {
        var oid = oid.oid
        let result = git_repository_set_head_detached(self.pointer, &oid)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_set_head"))
        }
        return .success(())
    }

    /// Set HEAD to the given reference.
    public func setHEAD(_ reference: ReferenceType) -> Result<(), NSError> {
        let result = git_repository_set_head(self.pointer, reference.longName)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_set_head"))
        }
        return .success(())
    }

    /// Check out HEAD.
    public func checkout(strategy: CheckoutStrategy, progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
        var options = checkoutOptions(strategy: strategy, progress: progress)

        let result = git_checkout_head(self.pointer, &options)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_checkout_head"))
        }

        return .success(())
    }

    /// Check out the given OID.
    public func checkout(_ oid: OID, strategy: CheckoutStrategy,
                         progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
        return setHEAD(oid).flatMap { self.checkout(strategy: strategy, progress: progress) }
    }

    /// Check out the given reference.
    public func checkout(_ reference: ReferenceType, strategy: CheckoutStrategy,
                         progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
        return setHEAD(reference).flatMap { self.checkout(strategy: strategy, progress: progress) }
    }

    /// Load all commits in the specified branch in topological & time order descending
    public func commits(in branch: Branch) -> CommitIterator {
        return CommitIterator(repo: self, root: branch.oid.oid)
    }

    /// Load current commit
    func getCurrentCommit() -> Result<Commit, NSError> {
        HEAD().flatMap { commit($0.oid) }
    }

    /// Get the index for the repo. The caller is responsible for freeing the index.
    func unsafeIndex() -> Result<OpaquePointer, NSError> {
        var index: OpaquePointer?
        let result = git_repository_index(&index, self.pointer)
        guard result == GIT_OK.rawValue, let index else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_index"))
        }
        return .success(index)
    }

    /// Stage the file(s) under the specified path.
    public func add(path: String) -> Result<(), NSError> {
        let nsPath = path as NSString
        guard let utf8Path = nsPath.utf8String else {
            return .failure(NSError(
                domain: libGit2ErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to convert path to UTF-8."]
            ))
        }
        var dirPointer: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer<CChar>(mutating: utf8Path)
        var paths = withUnsafeMutablePointer(to: &dirPointer) {
            git_strarray(strings: $0, count: 1)
        }
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            let addResult = git_index_add_all(index, &paths, 0, nil, nil)
            guard addResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: addResult, pointOfFailure: "git_index_add_all"))
            }
            let writeResult = git_index_write(index)
            guard writeResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: writeResult, pointOfFailure: "git_index_write"))
            }
            return .success(())
        }
    }

    /// Perform a commit with arbitrary numbers of parent commits.
    public func commit(
        tree treeOID: OID,
        parents: [Commit],
        message: String,
        signature: Signature
    ) -> Result<Commit, NSError> {
        return signature.makeUnsafeSignature().flatMap { signature in
            defer { git_signature_free(signature) }
            var tree: OpaquePointer?
            var treeOIDCopy = treeOID.oid
            let lookupResult = git_tree_lookup(&tree, self.pointer, &treeOIDCopy)
            guard lookupResult == GIT_OK.rawValue, let tree else {
                return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_tree_lookup"))
            }
            defer { git_tree_free(tree) }

            var msgBuf = git_buf()
            git_message_prettify(&msgBuf, message, 0, 35)
            defer { git_buf_free(&msgBuf) }

            var parentGitCommits: [OpaquePointer] = []
            defer {
                for commit in parentGitCommits {
                    git_commit_free(commit)
                }
            }
            for parentCommit in parents {
                var parent: OpaquePointer?
                var oid = parentCommit.oid.oid
                let lookupResult = git_commit_lookup(&parent, self.pointer, &oid)
                guard lookupResult == GIT_OK.rawValue, let parent else {
                    return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_commit_lookup"))
                }
                parentGitCommits.append(parent)
            }

            let parentsContiguous = ContiguousArray<OpaquePointer?>(parentGitCommits)
            return parentsContiguous.withUnsafeBufferPointer { unsafeBuffer in
                var commitOID = git_oid()
                let parentsPtr = UnsafeMutablePointer(mutating: unsafeBuffer.baseAddress)
                let result = git_commit_create(
                    &commitOID,
                    self.pointer,
                    "HEAD",
                    signature,
                    signature,
                    "UTF-8",
                    msgBuf.ptr,
                    tree,
                    parents.count,
                    parentsPtr
                )
                guard result == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: result, pointOfFailure: "git_commit_create"))
                }
                return commit(OID(commitOID))
            }
        }
    }

    /// Perform a commit of the staged files with the specified message and signature,
    /// assuming we are not doing a merge and using the current tip as the parent.
    public func commit(message: String, signature: Signature) -> Result<Commit, NSError> {
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            var treeOID = git_oid()
            let treeResult = git_index_write_tree(&treeOID, index)
            guard treeResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: treeResult, pointOfFailure: "git_index_write_tree"))
            }
            var parentID = git_oid()
            let nameToIDResult = git_reference_name_to_id(&parentID, self.pointer, "HEAD")
            guard nameToIDResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: nameToIDResult, pointOfFailure: "git_reference_name_to_id"))
            }
            return commit(OID(parentID)).flatMap { parentCommit in
                commit(tree: OID(treeOID), parents: [parentCommit], message: message, signature: signature)
            }
        }
    }

    // MARK: - Diffs

    public func diff(for commit: Commit) -> Result<Diff, NSError> {
        guard !commit.parents.isEmpty else {
            return self.diff(from: nil, to: commit.oid)
        }

        var mergeDiff: OpaquePointer?
        defer { git_object_free(mergeDiff) }
        for parent in commit.parents {
            let error = self.diff(from: parent.oid, to: commit.oid) {
                switch $0 {
                case .failure(let error):
                    return error

                case .success(let newDiff):
                    if mergeDiff == nil {
                        mergeDiff = newDiff
                    } else {
                        let mergeResult = git_diff_merge(mergeDiff, newDiff)
                        guard mergeResult == GIT_OK.rawValue else {
                            return NSError(gitError: mergeResult, pointOfFailure: "git_diff_merge")
                        }
                    }
                    return nil
                }
            }

            if let error {
                return .failure(error)
            }
        }

        guard let mergeDiff else {
            return .failure(NSError(
                domain: libGit2ErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compute merge diff."]
            ))
        }
        return .success(Diff(mergeDiff))
    }

    private func diff(
        from oldCommitOid: OID?,
        to newCommitOid: OID?,
        transform: (Result<OpaquePointer, NSError>) -> NSError?
    ) -> NSError? {
        assert(oldCommitOid != nil || newCommitOid != nil,
               "It is an error to pass nil for both the oldOid and newOid")

        var oldTree: OpaquePointer?
        defer { git_object_free(oldTree) }
        if let oid = oldCommitOid {
            switch unsafeTreeForCommitId(oid) {
            case .failure(let error):
                return transform(.failure(error))
            case .success(let value):
                oldTree = value
            }
        }

        var newTree: OpaquePointer?
        defer { git_object_free(newTree) }
        if let oid = newCommitOid {
            switch unsafeTreeForCommitId(oid) {
            case .failure(let error):
                return transform(.failure(error))
            case .success(let value):
                newTree = value
            }
        }

        var diff: OpaquePointer?
        let diffResult = git_diff_tree_to_tree(&diff,
                                                self.pointer,
                                                oldTree,
                                                newTree,
                                                nil)

        guard diffResult == GIT_OK.rawValue, let diff else {
            return transform(.failure(NSError(gitError: diffResult,
                                               pointOfFailure: "git_diff_tree_to_tree")))
        }

        return transform(.success(diff))
    }

    /// Memory safe
    private func diff(from oldCommitOid: OID?, to newCommitOid: OID?) -> Result<Diff, NSError> {
        assert(oldCommitOid != nil || newCommitOid != nil,
               "It is an error to pass nil for both the oldOid and newOid")

        var oldTree: Tree?
        if let oldCommitOid {
            switch safeTreeForCommitId(oldCommitOid) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                oldTree = value
            }
        }

        var newTree: Tree?
        if let newCommitOid {
            switch safeTreeForCommitId(newCommitOid) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                newTree = value
            }
        }

        if let oldTree, let newTree {
            return withGitObjects([oldTree.oid, newTree.oid], type: GIT_OBJECT_TREE) { objects in
                var diff: OpaquePointer?
                let diffResult = git_diff_tree_to_tree(&diff,
                                                       self.pointer,
                                                       objects[0],
                                                       objects[1],
                                                       nil)
                return processTreeToTreeDiff(diffResult, diff: diff)
            }
        } else if let tree = oldTree {
            return withGitObject(tree.oid, type: GIT_OBJECT_TREE, transform: { tree in
                var diff: OpaquePointer?
                let diffResult = git_diff_tree_to_tree(&diff,
                                                       self.pointer,
                                                       tree,
                                                       nil,
                                                       nil)
                return processTreeToTreeDiff(diffResult, diff: diff)
            })
        } else if let tree = newTree {
            return withGitObject(tree.oid, type: GIT_OBJECT_TREE, transform: { tree in
                var diff: OpaquePointer?
                let diffResult = git_diff_tree_to_tree(&diff,
                                                       self.pointer,
                                                       nil,
                                                       tree,
                                                       nil)
                return processTreeToTreeDiff(diffResult, diff: diff)
            })
        }

        return .failure(NSError(gitError: -1, pointOfFailure: "diff(from: to:)"))
    }

    private func processTreeToTreeDiff(_ diffResult: Int32, diff: OpaquePointer?) -> Result<Diff, NSError> {
        guard diffResult == GIT_OK.rawValue, let diff else {
            return .failure(NSError(gitError: diffResult,
                                    pointOfFailure: "git_diff_tree_to_tree"))
        }

        let diffObj = Diff(diff)
        git_diff_free(diff)
        return .success(diffObj)
    }

    private func processDiffDeltas(_ diffResult: OpaquePointer) -> Result<[Diff.Delta], NSError> {
        var returnDict = [Diff.Delta]()

        let count = git_diff_num_deltas(diffResult)

        for i in 0..<count {
            guard let delta = git_diff_get_delta(diffResult, i) else { continue }
            let gitDiffDelta = Diff.Delta(delta.pointee)
            returnDict.append(gitDiffDelta)
        }

        return .success(returnDict)
    }

    private func safeTreeForCommitId(_ oid: OID) -> Result<Tree, NSError> {
        return withGitObject(oid, type: GIT_OBJECT_COMMIT) { commit in
            guard let treeId = git_commit_tree_id(commit) else {
                return .failure(NSError(gitError: -1, pointOfFailure: "git_commit_tree_id"))
            }
            return tree(OID(treeId.pointee))
        }
    }

    /// Caller responsible to free returned tree with git_object_free
    private func unsafeTreeForCommitId(_ oid: OID) -> Result<OpaquePointer, NSError> {
        var commit: OpaquePointer?
        var oid = oid.oid
        let commitResult = git_object_lookup(&commit, self.pointer, &oid, GIT_OBJECT_COMMIT)
        guard commitResult == GIT_OK.rawValue, let commit else {
            return .failure(NSError(gitError: commitResult, pointOfFailure: "git_object_lookup"))
        }

        var tree: OpaquePointer?
        let treeId = git_commit_tree_id(commit)
        let treeResult = git_object_lookup(&tree, self.pointer, treeId, GIT_OBJECT_TREE)

        git_object_free(commit)

        guard treeResult == GIT_OK.rawValue, let tree else {
            return .failure(NSError(gitError: treeResult, pointOfFailure: "git_object_lookup"))
        }

        return .success(tree)
    }

    // MARK: - Reset

    public enum ResetType: Int32, Sendable {
        case soft = 1
        case mixed = 2
        case hard = 3
    }

    public func reset(_ target: OID, resetType: ResetType) -> Result<(), NSError> {
        var targetOid = target.oid
        var obj: OpaquePointer?
        let lookupResult = git_object_lookup(&obj, pointer, &targetOid, GIT_OBJECT_ANY)
        guard lookupResult == GIT_OK.rawValue, obj != nil else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_object_lookup"))
        }
        defer { git_object_free(obj) }

        let targetType = git_object_type(obj)
        if targetType == GIT_OBJECT_TAG {
            var dereferenced: OpaquePointer?
            let derefResult = git_object_peel(&dereferenced, obj, GIT_OBJECT_COMMIT)
            guard derefResult == GIT_OK.rawValue, dereferenced != nil else {
                return .failure(NSError(gitError: derefResult, pointOfFailure: "git_object_peel"))
            }
            git_object_free(obj)
            obj = dereferenced
        }

        let result: Int32
        if resetType == .hard {
            var opts = checkoutOptions(strategy: .Force)
            result = git_reset(pointer, obj, git_reset_t(rawValue: UInt32(resetType.rawValue)), &opts)
        } else {
            result = git_reset(pointer, obj, git_reset_t(rawValue: UInt32(resetType.rawValue)), nil)
        }

        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_reset"))
        }
        return .success(())
    }

    public func resetDefault(_ target: OID?, paths: [String]) -> Result<(), NSError> {
        var obj: OpaquePointer?
        if let target {
            var targetOid = target.oid
            let lookupResult = git_object_lookup(&obj, pointer, &targetOid, GIT_OBJECT_COMMIT)
            guard lookupResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_object_lookup"))
            }
        }
        defer { if let obj { git_object_free(obj) } }

        let cStrings = paths.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var mutableStrings = cStrings + [nil]
        return mutableStrings.withUnsafeMutableBufferPointer { buffer in
            var pathspec = git_strarray()
            pathspec.strings = buffer.baseAddress
            pathspec.count = cStrings.count

            let result = git_reset_default(pointer, obj, &pathspec)
            guard result == GIT_OK.rawValue else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_reset_default"))
            }
            return .success(())
        }
    }

    public func resolveRevision(_ revision: String) -> Result<OID, NSError> {
        var obj: OpaquePointer?
        let result = git_revparse_single(&obj, pointer, revision)
        guard result == GIT_OK.rawValue, let obj else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_revparse_single"))
        }
        let oid = OID(git_object_id(obj).pointee)
        git_object_free(obj)
        return .success(oid)
    }

    // MARK: - Status

    public func status() -> Result<[StatusEntry], NSError> {
        var returnArray = [StatusEntry]()

        var options = git_status_options()
        let optionsResult = git_status_init_options(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        guard optionsResult == GIT_OK.rawValue else {
            return .failure(NSError(gitError: optionsResult, pointOfFailure: "git_status_init_options"))
        }

        var unsafeStatus: OpaquePointer?
        defer { git_status_list_free(unsafeStatus) }
        let statusResult = git_status_list_new(&unsafeStatus, self.pointer, &options)
        guard statusResult == GIT_OK.rawValue, let unwrapStatusResult = unsafeStatus else {
            return .failure(NSError(gitError: statusResult, pointOfFailure: "git_status_list_new"))
        }

        let count = git_status_list_entrycount(unwrapStatusResult)

        for i in 0..<count {
            guard let s = git_status_byindex(unwrapStatusResult, i) else { continue }
            if s.pointee.status.rawValue == GIT_STATUS_CURRENT.rawValue {
                continue
            }

            let statusEntry = StatusEntry(from: s.pointee)
            returnArray.append(statusEntry)
        }

        return .success(returnArray)
    }

    // MARK: - Validity/Existence Check

    /// - returns: `.success(true)` iff there is a git repository at `url`,
    ///   `.success(false)` if there isn't,
    ///   and a `.failure` if there's been an error.
    public static func isValid(url: URL) -> Result<Bool, NSError> {
        var pointer: OpaquePointer?

        let result = url.withUnsafeFileSystemRepresentation {
            git_repository_open_ext(&pointer, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }

        switch result {
        case GIT_ENOTFOUND.rawValue:
            return .success(false)
        case GIT_OK.rawValue:
            return .success(true)
        default:
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_open_ext"))
        }
    }

    // MARK: - Stash

    public func stashList() -> Result<[StashEntry], NSError> {
        var entries: [StashEntry] = []
        let ctx = UnsafeMutablePointer<([StashEntry], NSError?)>.allocate(capacity: 1)
        ctx.initialize(to: (entries, nil))
        defer { ctx.deallocate() }
        let result = git_stash_foreach(pointer, { index, message, stashId, payload in
            guard let payload else { return 0 }
            let ctx = payload.assumingMemoryBound(to: ([StashEntry], NSError?).self)
            let msg = message.map { String(validatingUTF8: $0) ?? "" } ?? ""
            let oid = OID(stashId!.pointee)
            ctx.pointee.0.append(StashEntry(index: index, oid: oid, message: msg))
            return 0
        }, ctx)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_stash_foreach"))
        }
        return .success(ctx.pointee.0)
    }

    public func stashSave(message: String?, signature: Signature, includeUntracked: Bool) -> Result<OID, NSError> {
        return signature.makeUnsafeSignature().flatMap { sig in
            defer { git_signature_free(sig) }
            var out = git_oid()
            var flags: UInt32 = 0
            if includeUntracked { flags |= UInt32(GIT_STASH_INCLUDE_UNTRACKED.rawValue) }
            let result = git_stash_save(&out, pointer, sig, message, flags)
            guard result == GIT_OK.rawValue else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_stash_save"))
            }
            return .success(OID(out))
        }
    }

    public func stashApply(index: Int, reinstateIndex: Bool) -> Result<(), NSError> {
        var opts = git_stash_apply_options()
        git_stash_apply_options_init(&opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        if reinstateIndex { opts.flags |= UInt32(GIT_STASH_APPLY_REINSTATE_INDEX.rawValue) }
        opts.checkout_options = checkoutOptions(strategy: .Force)
        let result = git_stash_apply(pointer, index, &opts)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_stash_apply"))
        }
        return .success(())
    }

    public func stashPop(index: Int, reinstateIndex: Bool) -> Result<(), NSError> {
        var opts = git_stash_apply_options()
        git_stash_apply_options_init(&opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        if reinstateIndex { opts.flags |= UInt32(GIT_STASH_APPLY_REINSTATE_INDEX.rawValue) }
        opts.checkout_options = checkoutOptions(strategy: .Force)
        let result = git_stash_pop(pointer, index, &opts)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_stash_pop"))
        }
        return .success(())
    }

    public func stashDrop(index: Int) -> Result<(), NSError> {
        let result = git_stash_drop(pointer, index)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_stash_drop"))
        }
        return .success(())
    }

    // MARK: - Merge

    public func mergeAnalysis(branch: String, credentials: Credentials = .default) -> Result<MergeAnalysisResult, NSError> {
        var annotatedCommit: OpaquePointer?
        let annotatedResult = branch.withCString { branchStr in
            git_annotated_commit_from_revspec(&annotatedCommit, pointer, branchStr)
        }
        guard annotatedResult == GIT_OK.rawValue, annotatedCommit != nil else {
            return .failure(NSError(gitError: annotatedResult, pointOfFailure: "git_annotated_commit_from_revspec"))
        }
        defer { git_annotated_commit_free(annotatedCommit) }

        var analysis: git_merge_analysis_t = git_merge_analysis_t(rawValue: 0)
        var preference: git_merge_preference_t = git_merge_preference_t(rawValue: 0)
        var annotatedCommitPtr: OpaquePointer? = annotatedCommit
        let result = git_merge_analysis(&analysis, &preference, pointer, &annotatedCommitPtr, 1)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_merge_analysis"))
        }
        return .success(MergeAnalysisResult(
            upToDate: (analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue) != 0,
            fastForward: (analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue) != 0,
            normal: (analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue) != 0,
            unborn: (analysis.rawValue & GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0
        ))
    }

    public func merge(branch: String) -> Result<MergeResult, NSError> {
        var annotatedCommit: OpaquePointer?
        let annotatedResult = branch.withCString { branchStr in
            git_annotated_commit_from_revspec(&annotatedCommit, pointer, branchStr)
        }
        guard annotatedResult == GIT_OK.rawValue, annotatedCommit != nil else {
            return .failure(NSError(gitError: annotatedResult, pointOfFailure: "git_annotated_commit_from_revspec"))
        }
        defer { git_annotated_commit_free(annotatedCommit) }

        var mergeOpts = git_merge_options()
        git_merge_options_init(&mergeOpts, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var checkoutOpts = checkoutOptions(strategy: .Force)
        var annotatedCommitPtr: OpaquePointer? = annotatedCommit
        let result = git_merge(pointer, &annotatedCommitPtr, 1, &mergeOpts, &checkoutOpts)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_merge"))
        }

        let hasConflicts = unsafeIndex().map { idx in
            let count = git_index_has_conflicts(idx)
            git_index_free(idx)
            return count != 0
        }.getOrDefault(false)

        return .success(MergeResult(hasConflicts: hasConflicts))
    }

    public func mergeBase(_ one: OID, _ two: OID) -> Result<OID, NSError> {
        var out = git_oid()
        var o1 = one.oid
        var o2 = two.oid
        let result = git_merge_base(&out, pointer, &o1, &o2)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_merge_base"))
        }
        return .success(OID(out))
    }

    public func stateCleanup() -> Result<(), NSError> {
        let result = git_repository_state_cleanup(pointer)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_state_cleanup"))
        }
        return .success(())
    }

    // MARK: - Cherry-pick

    public func cherryPick(commitOID: OID) -> Result<Bool, NSError> {
        var commitPtr: OpaquePointer?
        var oid = commitOID.oid
        let lookupResult = git_commit_lookup(&commitPtr, pointer, &oid)
        guard lookupResult == GIT_OK.rawValue, let commitPtr else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_commit_lookup"))
        }
        defer { git_commit_free(commitPtr) }

        var opts = git_cherrypick_options()
        git_cherrypick_options_init(&opts, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION))
        opts.checkout_opts = checkoutOptions(strategy: .Force)

        let result = git_cherrypick(pointer, commitPtr, &opts)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_cherrypick"))
        }

        let hasConflicts = unsafeIndex().map { idx in
            let count = git_index_has_conflicts(idx)
            git_index_free(idx)
            return count != 0
        }.getOrDefault(false)

        return .success(hasConflicts)
    }

    // MARK: - Revert

    public func revert(commitOID: OID) -> Result<Bool, NSError> {
        var commitPtr: OpaquePointer?
        var oid = commitOID.oid
        let lookupResult = git_commit_lookup(&commitPtr, pointer, &oid)
        guard lookupResult == GIT_OK.rawValue, let commitPtr else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_commit_lookup"))
        }
        defer { git_commit_free(commitPtr) }

        var opts = git_revert_options()
        git_revert_options_init(&opts, UInt32(GIT_REVERT_OPTIONS_VERSION))
        opts.checkout_opts = checkoutOptions(strategy: .Force)

        let result = git_revert(pointer, commitPtr, &opts)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_revert"))
        }

        let hasConflicts = unsafeIndex().map { idx in
            let count = git_index_has_conflicts(idx)
            git_index_free(idx)
            return count != 0
        }.getOrDefault(false)

        return .success(hasConflicts)
    }

    // MARK: - Branch Delete

    public func deleteBranch(named name: String) -> Result<(), NSError> {
        var ref: OpaquePointer?
        let lookupResult = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        guard lookupResult == GIT_OK.rawValue, let ref else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_branch_lookup"))
        }
        defer { git_reference_free(ref) }
        let result = git_branch_delete(ref)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_branch_delete"))
        }
        return .success(())
    }

    // MARK: - Tag Create

    @discardableResult
    public func createTag(name: String, targetOID: OID, message: String?, tagger: Signature) -> Result<OID, NSError> {
        var targetObj: OpaquePointer?
        var tgtOid = targetOID.oid
        let lookupResult = git_object_lookup(&targetObj, pointer, &tgtOid, GIT_OBJECT_ANY)
        guard lookupResult == GIT_OK.rawValue, let targetObj else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_object_lookup"))
        }
        defer { git_object_free(targetObj) }

        let tagName = "refs/tags/" + name
        var existingRef: OpaquePointer?
        let exists = git_reference_lookup(&existingRef, pointer, tagName)
        if existingRef != nil { git_reference_free(existingRef) }
        guard exists != GIT_OK.rawValue else {
            return .failure(NSError(
                domain: libGit2ErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Tag '\(name)' already exists."]
            ))
        }

        var out = git_oid()
        if let message {
            return tagger.makeUnsafeSignature().flatMap { sig in
                defer { git_signature_free(sig) }
                let result = name.withCString { nameStr in
                    message.withCString { msgStr in
                        git_tag_create(&out, pointer, nameStr, targetObj, sig, msgStr, 0)
                    }
                }
                guard result == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: result, pointOfFailure: "git_tag_create"))
                }
                return .success(OID(out))
            }
        } else {
            let result = name.withCString { nameStr in
                git_tag_create_lightweight(&out, pointer, nameStr, targetObj, 0)
            }
            guard result == GIT_OK.rawValue else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_tag_create_lightweight"))
            }
            return .success(OID(out))
        }
    }

    public func deleteTag(named name: String) -> Result<(), NSError> {
        let result = name.withCString { nameStr in
            git_tag_delete(pointer, nameStr)
        }
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_tag_delete"))
        }
        return .success(())
    }

    // MARK: - Remote Add / Remove

    public func addRemote(name: String, url: String) -> Result<(), NSError> {
        var remote: OpaquePointer?
        let result = name.withCString { nameStr in
            url.withCString { urlStr in
                git_remote_create(&remote, pointer, nameStr, urlStr)
            }
        }
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_remote_create"))
        }
        if let remote { git_remote_free(remote) }
        return .success(())
    }

    public func removeRemote(name: String) -> Result<(), NSError> {
        let result = name.withCString { nameStr in
            git_remote_delete(pointer, nameStr)
        }
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_remote_delete"))
        }
        return .success(())
    }

    // MARK: - Remove (git rm)

    public func remove(paths: [String]) -> Result<(), NSError> {
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            let cStrings = paths.compactMap { strdup($0) }
            defer { cStrings.forEach { free($0) } }
            var mutableStrings = cStrings + [nil]
            return mutableStrings.withUnsafeMutableBufferPointer { buffer in
                var pathspec = git_strarray()
                pathspec.strings = buffer.baseAddress
                pathspec.count = cStrings.count
                let removeResult = git_index_remove_all(index, &pathspec, nil, nil)
                guard removeResult == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: removeResult, pointOfFailure: "git_index_remove_all"))
                }
                let writeResult = git_index_write(index)
                guard writeResult == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: writeResult, pointOfFailure: "git_index_write"))
                }
                return .success(())
            }
        }
    }

    // MARK: - Show (commit detail)

    public func show(oid: OID) -> Result<CommitDetail, NSError> {
        return commit(oid).map { c in
            let parentOIDs = c.parents.map { String($0.oid.description.prefix(7)) }
            let diffStr: String
            switch diff(for: c) {
            case .success(let d):
                diffStr = d.deltas.map { delta in
                    let s: String
                    switch delta.status.rawValue {
                    case 65: s = "A"
                    case 68: s = "D"
                    case 77: s = "M"
                    case 82: s = "R"
                    case 84: s = "T"
                    default: s = "?"
                    }
                    let old = delta.oldFile?.path ?? "?"
                    let new = delta.newFile?.path ?? "?"
                    return old == new ? "  \(s) \(old)" : "  \(s) \(old) → \(new)"
                }.joined(separator: "\n")
            case .failure: diffStr = ""
            }
            return CommitDetail(
                oid: c.oid,
                message: c.message,
                author: c.author,
                committer: c.committer,
                parentOIDs: parentOIDs,
                diff: diffStr
            )
        }
    }

    // MARK: - Blame

    public func blame(path: String, commitOID: OID? = nil) -> Result<[BlameHunk], NSError> {
        var opts = git_blame_options()
        git_blame_init_options(&opts, UInt32(GIT_BLAME_OPTIONS_VERSION))
        if let commitOID {
            opts.newest_commit = commitOID.oid
        }
        var blame: OpaquePointer?
        let result = path.withCString { pathStr in
            git_blame_file(&blame, pointer, pathStr, &opts)
        }
        guard result == GIT_OK.rawValue, let blame else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_blame_file"))
        }
        defer { git_blame_free(blame) }

        let count = git_blame_get_hunk_count(blame)
        var hunks: [BlameHunk] = []
        for i in 0..<count {
            guard let hunk = git_blame_get_hunk_byindex(blame, i) else { continue }
            let h = hunk.pointee
            let sig = h.final_signature.map { Signature($0.pointee) }
                ?? Signature(name: "Unknown", email: "")
            let commitOID = OID(h.final_commit_id)
            var mutId = h.final_commit_id
            let isCommitted = git_oid_is_zero(&mutId) == 0
            hunks.append(BlameHunk(
                linesInHunk: Int(h.lines_in_hunk),
                finalCommitOID: isCommitted ? commitOID : nil,
                author: sig,
                path: h.orig_path.map { String(validatingUTF8: $0) ?? "" } ?? "",
                finalStartLineNumber: Int(h.final_start_line_number)
            ))
        }
        return .success(hunks)
    }

    // MARK: - Reflog

    public func reflog(reference: String = "HEAD") -> Result<[ReflogEntry], NSError> {
        var reflog: OpaquePointer?
        let result = reference.withCString { refStr in
            git_reflog_read(&reflog, pointer, refStr)
        }
        guard result == GIT_OK.rawValue, let reflog else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_reflog_read"))
        }
        defer { git_reflog_free(reflog) }

        let count = git_reflog_entrycount(reflog)
        var entries: [ReflogEntry] = []
        for i in 0..<count {
            guard let entry = git_reflog_entry_byindex(reflog, i) else { continue }
            let oldOID = OID(git_reflog_entry_id_old(entry)!.pointee)
            let newOID = OID(git_reflog_entry_id_new(entry)!.pointee)
            let sig = Signature(git_reflog_entry_committer(entry)!.pointee)
            let msgPtr = git_reflog_entry_message(entry)
            let msg = msgPtr.map { String(validatingUTF8: $0) ?? "" } ?? ""
            entries.append(ReflogEntry(oldOID: oldOID, newOID: newOID, committer: sig, message: msg))
        }
        return .success(entries)
    }

    // MARK: - Config

    public func getConfig(_ key: String) -> Result<String, NSError> {
        var cfg: OpaquePointer?
        let cfgResult = git_repository_config(&cfg, pointer)
        guard cfgResult == GIT_OK.rawValue, let cfg else {
            return .failure(NSError(gitError: cfgResult, pointOfFailure: "git_repository_config"))
        }
        defer { git_config_free(cfg) }
        var buf = git_buf()
        let result = key.withCString { keyStr in
            git_config_get_string_buf(&buf, cfg, keyStr)
        }
        guard result == GIT_OK.rawValue else {
            git_buf_free(&buf)
            return .failure(NSError(gitError: result, pointOfFailure: "git_config_get_string_buf"))
        }
        defer { git_buf_free(&buf) }
        let value = String(validatingUTF8: buf.ptr) ?? ""
        return .success(value)
    }

    public func setConfig(_ key: String, value: String) -> Result<(), NSError> {
        var cfg: OpaquePointer?
        let cfgResult = git_repository_config(&cfg, pointer)
        guard cfgResult == GIT_OK.rawValue, let cfg else {
            return .failure(NSError(gitError: cfgResult, pointOfFailure: "git_repository_config"))
        }
        defer { git_config_free(cfg) }
        let result = key.withCString { keyStr in
            value.withCString { valStr in
                git_config_set_string(cfg, keyStr, valStr)
            }
        }
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_config_set_string"))
        }
        return .success(())
    }

    // MARK: - Describe

    public func describe(commitOID: OID?, tags: Bool = true, alwaysUseLongFormat: Bool = false) -> Result<String, NSError> {
        var obj: OpaquePointer?
        if let commitOID {
            var oid = commitOID.oid
            let lookupResult = git_object_lookup(&obj, pointer, &oid, GIT_OBJECT_COMMIT)
            guard lookupResult == GIT_OK.rawValue, obj != nil else {
                return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_object_lookup"))
            }
        } else {
            let headResult = git_revparse_single(&obj, pointer, "HEAD")
            guard headResult == GIT_OK.rawValue, obj != nil else {
                return .failure(NSError(gitError: headResult, pointOfFailure: "git_revparse_single"))
            }
        }
        defer { git_object_free(obj) }

        var opts = git_describe_options()
        git_describe_init_options(&opts, UInt32(GIT_DESCRIBE_OPTIONS_VERSION))
        if tags { opts.describe_strategy = GIT_DESCRIBE_TAGS.rawValue }

        var resultPtr: OpaquePointer?
        let describeResult = git_describe_commit(&resultPtr, obj, &opts)
        guard describeResult == GIT_OK.rawValue, let resultPtr else {
            return .failure(NSError(gitError: describeResult, pointOfFailure: "git_describe_commit"))
        }
        defer { git_describe_result_free(resultPtr) }

        var formatOpts = git_describe_format_options()
        git_describe_init_format_options(&formatOpts, UInt32(GIT_DESCRIBE_FORMAT_OPTIONS_VERSION))
        if alwaysUseLongFormat { formatOpts.always_use_long_format = 1 }
        var buf = git_buf()
        let formatResult = git_describe_format(&buf, resultPtr, &formatOpts)
        guard formatResult == GIT_OK.rawValue else {
            return .failure(NSError(gitError: formatResult, pointOfFailure: "git_describe_format"))
        }
        defer { git_buf_free(&buf) }
        let description = String(validatingUTF8: buf.ptr) ?? ""
        return .success(description)
    }

    // MARK: - Clean (remove untracked files)

    public func clean(directories: Bool = false) -> Result<Int, NSError> {
        var opts = git_status_options()
        git_status_init_options(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.flags = UInt32(GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue)
        if directories {
            opts.flags |= UInt32(GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue)
        }

        var statusList: OpaquePointer?
        let statusResult = git_status_list_new(&statusList, pointer, &opts)
        guard statusResult == GIT_OK.rawValue, let statusList else {
            return .failure(NSError(gitError: statusResult, pointOfFailure: "git_status_list_new"))
        }
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)
        var removed = 0
        guard let workdir = directoryURL else { return .success(0) }

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            guard entry.pointee.status.rawValue == GIT_STATUS_WT_NEW.rawValue else { continue }
            guard let deltaPtr = entry.pointee.index_to_workdir else { continue }
            guard let pathCStr = deltaPtr.pointee.new_file.path else { continue }
            let path = String(validatingUTF8: pathCStr) ?? ""
            let fileURL = workdir.appendingPathComponent(path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if directories {
                        try? FileManager.default.removeItem(at: fileURL)
                        removed += 1
                    }
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                    removed += 1
                }
            }
        }
        return .success(removed)
    }
}

private extension Array {
    func aggregateResult<Value, Error>() -> Result<[Value], Error> where Element == Result<Value, Error> {
        var values: [Value] = []
        for result in self {
            switch result {
            case .success(let value):
                values.append(value)
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(values)
    }
}

private extension Result {
    func getOrDefault(_ default: Success) -> Success {
        switch self {
        case .success(let value): return value
        case .failure: return `default`
        }
    }
}
