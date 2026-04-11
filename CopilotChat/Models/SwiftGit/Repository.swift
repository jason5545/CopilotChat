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
    public func fetch(_ remote: Remote, credentials: Credentials = .default) -> Result<(), NSError> {
        return remoteLookup(named: remote.name) { remote in
            remote.flatMap { pointer in
                return withFetchOptions(credentials: credentials) { opts in
                    let result = git_remote_fetch(pointer, nil, &opts, nil)
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
