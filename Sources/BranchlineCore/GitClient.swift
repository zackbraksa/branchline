import Foundation
import CryptoKit
import Darwin

public enum GitClientError: Error, LocalizedError, Sendable {
    case invalidRepository(String)
    case commandFailed(arguments: [String], status: Int32, message: String)
    case invalidData(String)
    case operationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let path): "Not a Git repository: \(path)"
        case .commandFailed(_, let status, let message): message.isEmpty ? "Git exited with status \(status)." : message
        case .invalidData(let message), .operationUnavailable(let message): message
        }
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var processGroup: pid_t?
    private var escalation: DispatchWorkItem?
    private var finished = false

    func install(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        let pid = process.processIdentifier
        if process.isRunning, pid > 0, getpgid(pid) == pid, pid != getpgrp() { processGroup = pid }
        if cancelled { stop() }
    }

    func terminate(timedOut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !cancelled else { return }
        cancelled = true
        self.timedOut = timedOut
        stop()
    }

    private func stop() {
        if let processGroup {
            killpg(processGroup, SIGTERM)
        } else if let process, process.isRunning {
            process.terminate()
        }
        guard process != nil, escalation == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.forceTerminate() }
        escalation = work
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func forceTerminate() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if let processGroup {
            killpg(processGroup, SIGKILL)
        } else if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        processGroup = nil
        escalation?.cancel()
        escalation = nil
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}

private final class ProcessBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }
    func output(status: Int32) -> GitOutput {
        lock.lock(); defer { lock.unlock() }
        return GitOutput(stdout: stdout, stderr: stderr, status: status)
    }
}

private struct GitOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

public actor GitClient {
    private var mutations: Set<String> = []
    private struct MutationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var mutationWaiters: [String: [MutationWaiter]] = [:]

    public init() {}

    public func pendingChanges(_ repo: Repository) async throws -> PendingChanges {
        let output = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=none"], at: repo.path)
        let records = output.stdout.split(separator: 0, omittingEmptySubsequences: true)
        var files: [PendingFile] = []
        var index = 0
        while index < records.count {
            guard let record = String(data: Data(records[index]), encoding: .utf8) else {
                throw GitClientError.operationUnavailable("A filename cannot be displayed safely as UTF-8. Review changes in Terminal.")
            }
            index += 1
            let kind = record.first
            let count = kind == "1" ? 8 : kind == "2" ? 9 : kind == "u" ? 10 : 1
            let fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == count + 1 else { continue }
            let path = fields[count]
            var oldPath: String?
            if kind == "2" {
                guard index < records.count, let original = String(data: Data(records[index]), encoding: .utf8) else {
                    throw GitClientError.operationUnavailable("A renamed filename cannot be displayed safely.")
                }
                oldPath = fields[8].hasPrefix("R") ? original : nil
                index += 1
            }
            let xy = kind == "?" ? "??" : fields[1]
            let submodule = count > 1 && (fields[2].hasPrefix("S") || fields.contains("160000"))
            let paths = [path] + (oldPath.map { [$0] } ?? [])
            let safe = paths.allSatisfy { safePendingPath($0, repo: repo) }
            let reason: String? = kind == "u" ? "Resolve this conflict in your editor or Terminal." : submodule ? "Review submodule changes in its own checkout." : !safe ? "Review this directory or linked path in Finder or Terminal." : nil
            files.append(PendingFile(path: path, oldPath: oldPath, indexStatus: String(xy.prefix(1)), worktreeStatus: String(xy.suffix(1)), unavailableReason: reason))
        }
        let head = try await run(["rev-parse", "--verify", "HEAD"], at: repo.path, allowFailure: true)
        let staged = try await run(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"], at: repo.path)
        var hash = SHA256()
        hash.update(data: output.stdout)
        hash.update(data: head.stdout)
        hash.update(data: staged.stdout)
        for file in files where file.unavailableReason == nil {
            for path in file.paths {
                let url = URL(fileURLWithPath: repo.path).appendingPathComponent(path)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                    hash.update(data: Data(String(describing: attributes[.posixPermissions]).utf8))
                    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                        hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
                    } else {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
                    }
                } else { hash.update(data: Data("missing".utf8)) }
            }
        }
        return PendingChanges(files: files, fingerprint: Data(hash.finalize()), hasHead: head.status == 0)
    }

    public func discardChanges(_ repo: Repository, snapshot: PendingChanges, paths: Set<String>) async throws -> URL {
        let key = try await commonDirectoryPath(repo)
        try await acquireMutation(for: key)
        defer { releaseMutation(for: key) }
        let current = try await pendingChanges(repo)
        guard current == snapshot else { throw GitClientError.operationUnavailable("Local changes have changed since you reviewed them. Refresh the list and try again.") }
        guard !(try await status(repo)).operationInProgress, current.hasHead else {
            throw GitClientError.operationUnavailable("Finish the current Git operation, or create the first commit, before discarding changes.")
        }
        let selected = current.files.filter { paths.contains($0.path) }
        guard !selected.isEmpty, selected.count == paths.count, selected.allSatisfy({ $0.unavailableReason == nil }) else {
            throw GitClientError.operationUnavailable("Select files that can be safely discarded.")
        }
        let allPaths = Array(Set(selected.flatMap(\.paths))).sorted()
        let affectedPaths = Set(allPaths)
        guard current.files.filter({ !paths.contains($0.path) }).allSatisfy({ affectedPaths.isDisjoint(with: $0.paths) }) else {
            throw GitClientError.operationUnavailable("A rename shares a path with another pending file. Select both files to discard them together.")
        }
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("Branchline discarded changes \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        do {
            for path in allPaths {
                let source = URL(fileURLWithPath: repo.path).appendingPathComponent(path)
                if (try? FileManager.default.attributesOfItem(atPath: source.path)) != nil {
                    let target = backup.appendingPathComponent("Files").appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
            let patch = try await run(["--literal-pathspecs", "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--"] + allPaths, at: repo.path)
            try patch.stdout.write(to: backup.appendingPathComponent("Staged changes.patch"))
            let note = "Repository: \(repo.path)\nFiles contains your working copies before discarding. Staged changes.patch preserves the staged changes relative to HEAD.\nSelected paths:\n" + allPaths.joined(separator: "\n")
            try Data(note.utf8).write(to: backup.appendingPathComponent("Recovery.txt"))
            guard try await pendingChanges(repo) == snapshot else {
                throw GitClientError.operationUnavailable("Files changed while preparing the backup. Refresh and try again.")
            }
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: backup, resultingItemURL: &trashURL)
        let recovery = (trashURL as URL?) ?? backup
        do {
            let tracked = Array(Set(selected.filter { $0.indexStatus != "?" }.flatMap(\.paths))).sorted()
            for file in selected where file.indexStatus == "?" {
                let url = URL(fileURLWithPath: repo.path).appendingPathComponent(file.path)
                try FileManager.default.removeItem(at: url)
            }
            if !tracked.isEmpty {
                _ = try await run(["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--"] + tracked, at: repo.path, cancellationSensitive: false)
            }
        } catch {
            throw GitClientError.operationUnavailable("Discard did not finish: \(error.localizedDescription) Your backup, including staged changes, is in Trash: \(recovery.path)")
        }
        return recovery
    }

    private func safePendingPath(_ path: String, repo: Repository) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !parts.contains(".git"), !parts.contains("") else { return false }
        let root = URL(fileURLWithPath: repo.path).resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == url.deletingLastPathComponent().standardizedFileURL.path else { return false }
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
            return type == .typeRegular || type == .typeSymbolicLink
        }
        return true
    }

    public func validate(path: String) async throws -> Repository {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let result = try await run(["rev-parse", "--show-toplevel"], at: canonical)
        let root = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw GitClientError.invalidRepository(path) }
        return Repository(path: URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path)
    }

    public func status(_ repo: Repository) async throws -> RepositoryStatus {
        let output = try await run(["status", "--porcelain=v2", "-z", "--branch", "--ignore-submodules=none", "--untracked-files=all"], at: repo.path)
        let pieces = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changed = 0
        var index = 0
        while index < pieces.count {
            let piece = pieces[index]
            guard let text = String(data: Data(piece), encoding: .utf8), !text.isEmpty else { index += 1; continue }
            if text.hasPrefix("# ") {
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("# branch.head ") {
                        let value = String(line.dropFirst("# branch.head ".count))
                        branch = value == "(detached)" || value == "(unknown)" ? nil : value
                    } else if line.hasPrefix("# branch.upstream ") {
                        upstream = String(line.dropFirst("# branch.upstream ".count))
                    } else if line.hasPrefix("# branch.ab ") {
                        let fields = line.split(separator: " ")
                        if fields.count >= 4 {
                            ahead = Int(fields[2].dropFirst()) ?? 0
                            behind = Int(fields[3].dropFirst()) ?? 0
                        }
                    }
                }
            } else if text.hasPrefix("1 ") || text.hasPrefix("2 ") || text.hasPrefix("u ") || text.hasPrefix("? ") {
                changed += 1
                if text.hasPrefix("2 ") { index += 1 }
            }
            index += 1
        }
        return RepositoryStatus(branch: branch, defaultBranch: try await defaultBranchName(repo, currentBranch: branch),
                                upstream: upstream, ahead: ahead, behind: behind,
                                changedFiles: changed, operationInProgress: try await operationInProgress(at: repo.path))
    }

    public func history(_ repo: Repository, limit: Int, branch: String? = nil,
                        includeRemotes: Bool = false, scope: HistoryScope = .all) async throws -> HistoryPage {
        let refs = try await readRefs(repo, includeRemotes: includeRemotes)
        let maxCount = max(0, limit)
        var revArgs = ["rev-list", "--topo-order", "--max-count=\(maxCount + 1)"]
        if scope != .all {
            guard branch == nil else { throw GitClientError.operationUnavailable("Choose either a branch or a sync history filter.") }
            revArgs.append(try await historyRange(repo, scope: scope))
        } else if let branch {
            guard branch.hasPrefix("refs/") else { throw GitClientError.operationUnavailable("Select a full Git ref name.") }
            let resolved = try await run(["rev-parse", "--verify", "--end-of-options", "\(branch)^{commit}"], at: repo.path)
            let oid = String(decoding: resolved.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oid.isEmpty else { throw GitClientError.operationUnavailable("The selected ref does not point to a commit.") }
            revArgs.append(oid)
        } else {
            revArgs.append(contentsOf: refs.filter { $0.kind != .remoteBranch || includeRemotes }.map(\.fullName))
            revArgs.append("HEAD")
        }
        let revOutput = try await run(revArgs, at: repo.path, allowFailure: true)
        guard revOutput.status == 0 || refs.isEmpty && branch == nil && scope == .all else { throw commandError(revOutput, arguments: revArgs) }
        let ids = String(decoding: revOutput.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let hasMore = ids.count > maxCount
        let selected = Array(ids.prefix(maxCount))
        let commits = try await readCommits(selected, repo: repo)
        return HistoryPage(commits: commits, refs: refs, hasMore: hasMore)
    }

    private func historyRange(_ repo: Repository, scope: HistoryScope) async throws -> String {
        let branch = try await run(["symbolic-ref", "--quiet", "HEAD"], at: repo.path, allowFailure: true)
        guard branch.status == 0 else {
            throw GitClientError.operationUnavailable("Sync history requires an attached branch.")
        }
        func resolve(_ ref: String, message: String) async throws -> String {
            let output = try await run(["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"],
                                       at: repo.path, allowFailure: true)
            let oid = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.status == 0, !oid.isEmpty else { throw GitClientError.operationUnavailable(message) }
            return oid
        }
        let head = try await resolve("HEAD", message: "Sync history requires a current commit.")
        let upstream = try await resolve("@{upstream}", message: "The current branch has no available upstream commit.")
        return scope == .incoming ? "\(head)..\(upstream)" : "\(upstream)..\(head)"
    }

    public func commonDirectory(_ repo: Repository) async throws -> String {
        try await commonDirectoryPath(repo)
    }

    public func worktrees(_ repo: Repository) async throws -> [GitWorktree] {
        let output = try await run(["worktree", "list", "--porcelain", "-z"], at: repo.path)
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
        var result: [GitWorktree] = []
        var current: GitWorktree?
        for field in fields {
            let text = String(decoding: field, as: UTF8.self)
            if text.isEmpty {
                if let tree = current { result.append(tree); current = nil }
            } else if text.hasPrefix("worktree ") {
                let raw = String(text.dropFirst("worktree ".count))
                let path = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
                current = GitWorktree(path: path)
            } else if text.hasPrefix("HEAD ") {
                let head = String(text.dropFirst(5))
                current?.head = head.allSatisfy({ $0 == "0" }) ? nil : head
            } else if text.hasPrefix("branch refs/heads/") {
                current?.branch = String(text.dropFirst("branch refs/heads/".count))
            } else if text == "bare" { current?.isBare = true
            } else if text == "detached" { current?.isDetached = true
            } else if text == "locked" || text.hasPrefix("locked ") {
                current?.isLocked = true
                if text.hasPrefix("locked ") { current?.lockReason = String(text.dropFirst(7)) }
            } else if text == "prunable" || text.hasPrefix("prunable ") {
                current?.isPrunable = true
                if text.hasPrefix("prunable ") { current?.pruneReason = String(text.dropFirst(9)) }
            }
        }
        if let tree = current { result.append(tree) }
        return result
    }

    public func files(_ repo: Repository, commit: Commit) async throws -> [CommitFile] {
        let args: [String]
        if let parent = commit.parents.first {
            args = ["diff", "--name-status", "-z", "--find-renames", "--find-copies", parent, commit.id]
        } else {
            args = ["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "--find-renames", "--find-copies", commit.id]
        }
        let data = try await run(args, at: repo.path).stdout
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [CommitFile] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            index += 1
            guard !status.isEmpty else { continue }
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index + 1 < fields.count else { throw GitClientError.invalidData("Incomplete rename record from Git.") }
                let oldPath = fields[index]
                let newPath = fields[index + 1]
                index += 2
                result.append(CommitFile(path: newPath, oldPath: oldPath, status: status))
            } else {
                guard index < fields.count else { throw GitClientError.invalidData("Incomplete file record from Git.") }
                result.append(CommitFile(path: fields[index], status: status))
                index += 1
            }
        }
        return result
    }

    public func search(_ repo: Repository, query: String, scope: HistoryScope = .all) async throws -> [Commit] {
        guard !query.isEmpty else { return [] }
        let revision = scope == .all ? "--all" : try await historyRange(repo, scope: scope)
        let revArgs = ["rev-list", "--topo-order", revision]
        let output = try await run(revArgs, at: repo.path)
        let ids = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let commits = try await readCommits(ids, repo: repo)
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return commits.filter {
            [$0.id, $0.subject, $0.message, $0.authorName, $0.authorEmail]
                .contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }
        }
    }

    public func perform(_ operation: GitOperation, on repo: Repository,
                        onProgress: (@Sendable (GitOperationPhase) async -> Void)? = nil) async throws {
        let mutationKey = try await commonDirectoryPath(repo)
        try await acquireMutation(for: mutationKey)
        defer { releaseMutation(for: mutationKey) }
        try Task.checkCancellation()
        let current = try await status(repo)
        switch operation {
        case .fetch:
            _ = try await run(["fetch", "--all", "--no-prune", "--no-prune-tags"], at: repo.path, timeout: 120)
        case .pull:
            guard !current.operationInProgress else { throw GitClientError.operationUnavailable("Finish the current Git operation before pulling.") }
            guard current.changedFiles == 0 else { throw GitClientError.operationUnavailable("Review Changes to discard unwanted edits, or use Stash & Pull to keep them before pulling.") }
            guard let branch = current.branch else { throw GitClientError.operationUnavailable("Pull requires an attached local branch.") }
            guard current.upstream != nil else { throw GitClientError.operationUnavailable("The current branch has no upstream.") }
            let upstream = try await upstreamTarget(branch: branch, repo: repo)
            try await fastForwardPull(upstream, repo: repo)
        case .stashAndPull:
            try await stashAndPull(repo, onProgress: onProgress)
        case .push:
            guard !current.operationInProgress else { throw GitClientError.operationUnavailable("Finish the current Git operation before pushing.") }
            guard let branch = current.branch else { throw GitClientError.operationUnavailable("Push requires an attached local branch.") }
            let upstream = try await upstreamTarget(branch: branch, repo: repo)
            _ = try await run(["push", "--no-force", "--no-follow-tags", "--", upstream.remote, "HEAD:\(upstream.ref)"], at: repo.path, timeout: 120)
        }
    }

    public func performBackgroundFetch(on repo: Repository, timeout: TimeInterval = 60) async throws {
        let mutationKey = try await commonDirectoryPath(repo)
        try await acquireMutation(for: mutationKey)
        defer { releaseMutation(for: mutationKey) }
        try Task.checkCancellation()
        _ = try await run(["fetch", "--all", "--no-prune", "--no-prune-tags"], at: repo.path, timeout: timeout)
    }

    private struct SyncSnapshot {
        let repository: Repository
        let branch: String
        let head: String
        let upstream: UpstreamTarget
        let pushIdentity: String
        let fetchIdentity: String
        let fetchSpecs: [String]
        let uploadPack: String
        let receivePack: String
        let fetchOptions: [String]
    }

    public func pushDestinations(_ repositories: [Repository]) async -> [String: String] {
        var destinations: [String: String] = [:]
        for repository in repositories {
            guard !Task.isCancelled else { break }
            do {
                let current = try await status(repository)
                guard let branch = current.branch,
                      let upstream = try? await upstreamTarget(branch: branch, repo: repository),
                      upstream.remote != "." else { continue }
                destinations[repository.path] = try await remoteIdentity(upstream.remote, repo: repository) + "\0" + upstream.ref
            } catch { continue }
        }
        return destinations
    }

    public func synchronize(_ repositories: [Repository], mode: SyncMode,
                            timeout: TimeInterval, pushContext: [Repository] = [],
                            pushDestinations: [String: String]? = nil) async -> [RepositorySyncResult] {
        guard !repositories.isEmpty else { return [] }
        guard let first = repositories.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return repositories.map { .init(repository: $0, outcome: .skipped, reason: .unavailable) }
        }
        var fetched = false
        var results: [String: RepositorySyncResult] = [:]
        do {
            let mutationKey = try await commonDirectoryPath(first)
            try await acquireMutation(for: mutationKey)
            defer { releaseMutation(for: mutationKey) }
            try Task.checkCancellation()
            var snapshots: [String: SyncSnapshot] = [:]
            var seenPaths: Set<String> = []
            let preparationTargets = (repositories + pushContext).filter { seenPaths.insert($0.path).inserted }
            for repository in preparationTargets {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: repository.path) else {
                    results[repository.path] = .init(repository: repository, outcome: .skipped, reason: .unavailable)
                    continue
                }
                let current = try await status(repository)
                guard let branch = current.branch else {
                    results[repository.path] = .init(repository: repository, outcome: .skipped, reason: .detached)
                    continue
                }
                guard let upstream = try? await upstreamTarget(branch: branch, repo: repository) else {
                    results[repository.path] = .init(repository: repository, outcome: .skipped, reason: .missingUpstream)
                    continue
                }
                let identity = try await remoteIdentity(upstream.remote, repo: repository)
                snapshots[repository.path] = SyncSnapshot(repository: repository, branch: branch,
                                                        head: try await headOID(repository), upstream: upstream,
                                                        pushIdentity: identity + "\0" + upstream.ref,
                                                        fetchIdentity: try await remoteIdentity(upstream.remote, repo: repository, push: false),
                                                        fetchSpecs: try await fetchSpecs(upstream.remote, repo: repository),
                                                        uploadPack: try await uploadPackCommand(upstream.remote, repo: repository),
                                                        receivePack: try await remoteCommand(upstream.remote, key: "receivepack", repo: repository),
                                                        fetchOptions: try await fetchOptions(upstream.remote, repo: repository))
            }
            try await fetchSyncUpstreams(Array(snapshots.values), repo: first, timeout: timeout)
            fetched = true
            let duplicateTargets: Set<String>
            if let pushDestinations {
                duplicateTargets = Set(Dictionary(grouping: pushDestinations.values, by: { $0 }).filter { $0.value.count > 1 }.keys)
            } else {
                duplicateTargets = Set(Dictionary(grouping: snapshots.values.filter { $0.upstream.remote != "." },
                                                 by: \.pushIdentity).filter { $0.value.count > 1 }.keys)
            }
            for repository in repositories {
                try Task.checkCancellation()
                guard let snapshot = snapshots[repository.path] else {
                    if case .background(autoPull: false) = mode {
                        results[repository.path] = .init(repository: repository, outcome: .upToDate, message: "Fetched", fetched: true)
                    } else if let previous = results[repository.path] {
                        results[repository.path] = .init(repository: repository, outcome: previous.outcome,
                                                        reason: previous.reason, message: previous.message, fetched: true)
                    }
                    continue
                }
                if case .background(autoPull: false) = mode {
                    results[repository.path] = .init(repository: repository, outcome: .upToDate, message: "Fetched", fetched: true)
                    continue
                }
                if mode == .pushEligible, let pushDestinations,
                   pushDestinations[repository.path] != snapshot.pushIdentity {
                    results[repository.path] = .init(repository: repository, outcome: .skipped,
                                                    reason: .checkoutChanged, fetched: true)
                    continue
                }
                do {
                    results[repository.path] = try await applySync(snapshot, mode: mode,
                        ambiguousPush: duplicateTargets.contains(snapshot.pushIdentity), timeout: timeout)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    results[repository.path] = .init(repository: repository, outcome: .failed,
                                                    message: error.localizedDescription, fetched: true)
                }
            }
            return repositories.compactMap { results[$0.path] }
        } catch is CancellationError {
            return repositories.map { results[$0.path] ?? .init(repository: $0, outcome: .cancelled, fetched: fetched) }
        } catch {
            return repositories.map { .init(repository: $0, outcome: .failed, reason: .remoteCheckFailed,
                                            message: error.localizedDescription, fetched: fetched) }
        }
    }

    private func remoteIdentity(_ remote: String, repo: Repository, push: Bool = true) async throws -> String {
        guard remote != "." else { return "." }
        let output = try await run(["remote", "get-url"] + (push ? ["--push", "--all"] : []) + ["--", remote], at: repo.path)
        let raw = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        if raw.contains("\n") { return "multiple:\(raw)" }
        if let url = URL(string: raw), url.isFileURL { return url.standardizedFileURL.resolvingSymlinksInPath().path }
        if let colon = raw.firstIndex(of: ":"), raw.firstIndex(of: "/").map({ colon < $0 }) ?? true { return raw }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: repo.path).appendingPathComponent(expanded)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func fetchSyncUpstreams(_ snapshots: [SyncSnapshot], repo: Repository, timeout: TimeInterval) async throws {
        let output = try await run(["remote"], at: repo.path)
        let configured = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let required = Dictionary(grouping: snapshots.filter { $0.upstream.remote != "." }, by: { $0.upstream.remote })
        for remote in Set(configured).union(required.keys).sorted() {
            try Task.checkCancellation()
            try await validateSyncTransport(remote, repo: repo)
            let identity = try await remoteIdentity(remote, repo: repo, push: false)
            var specs = try await fetchSpecs(remote, repo: repo)
            let command = try await uploadPackCommand(remote, repo: repo)
            let options = try await fetchOptions(remote, repo: repo)
            for snapshot in required[remote] ?? [] {
                try await validateSyncTransport(remote, repo: snapshot.repository)
                guard snapshot.fetchIdentity == identity, snapshot.fetchSpecs == specs, snapshot.uploadPack == command, snapshot.fetchOptions == options else {
                    throw GitClientError.operationUnavailable("Linked checkouts have different upstream fetch configuration.")
                }
            }
            for snapshot in required[remote] ?? [] {
                let target = snapshot.upstream
                guard !specs.contains(where: { $0.hasPrefix("^") && refspecMatches(String($0.dropFirst()), ref: target.ref) }) else {
                    throw GitClientError.operationUnavailable("The upstream branch is excluded by the remote's fetch configuration.")
                }
                let spec = "+\(target.ref):\(target.trackingRef)"
                if !specs.contains(spec) { specs.append(spec) }
            }
            let uploadOption = command.isEmpty ? [] : ["--upload-pack=\(command)"]
            _ = try await run(["fetch", "--no-prune", "--no-prune-tags"] + uploadOption + options + ["--", identity] + specs,
                              at: repo.path, timeout: timeout)
        }
    }

    private func validateSyncTransport(_ remote: String, repo: Repository) async throws {
        guard remote != "." else { return }
        for key in ["proxy", "proxyAuthMethod", "vcs", "promisor", "partialclonefilter"] {
            let configured = try await run(["config", "--get", "remote.\(remote).\(key)"], at: repo.path, allowFailure: true)
            guard configured.status != 0 else {
                throw GitClientError.operationUnavailable("Remote-specific proxy, helper, or partial-clone settings require manual synchronization.")
            }
        }
    }

    private func fetchOptions(_ remote: String, repo: Repository) async throws -> [String] {
        guard remote != "." else { return [] }
        var options: [String] = []
        let tagOption = try await remoteCommand(remote, key: "tagOpt", repo: repo)
        if !tagOption.isEmpty {
            guard ["--tags", "--no-tags"].contains(tagOption) else {
                throw GitClientError.operationUnavailable("Unsupported remote tag configuration.")
            }
            options.append(tagOption)
        }
        let server = try await run(["config", "--null", "--get-all", "remote.\(remote).serverOption"], at: repo.path, allowFailure: true)
        if server.status == 0 {
            var values = String(decoding: server.stdout, as: UTF8.self).components(separatedBy: "\0")
            if values.last == "" { values.removeLast() }
            options += values.map { "--server-option=\($0)" }
        }
        return options
    }

    private func remoteCommand(_ remote: String, key: String, repo: Repository) async throws -> String {
        guard remote != "." else { return "" }
        let output = try await run(["config", "--get", "remote.\(remote).\(key)"], at: repo.path, allowFailure: true)
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func uploadPackCommand(_ remote: String, repo: Repository) async throws -> String {
        guard remote != "." else { return "" }
        return try await remoteCommand(remote, key: "uploadpack", repo: repo)
    }

    private func fetchSpecs(_ remote: String, repo: Repository) async throws -> [String] {
        guard remote != "." else { return [] }
        let config = try await run(["config", "--get-all", "remote.\(remote).fetch"], at: repo.path, allowFailure: true)
        return String(decoding: config.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    private func refspecMatches(_ pattern: String, ref: String) -> Bool {
        guard let star = pattern.firstIndex(of: "*") else { return pattern == ref }
        return ref.hasPrefix(String(pattern[..<star])) && ref.hasSuffix(String(pattern[pattern.index(after: star)...]))
    }

    private func applySync(_ snapshot: SyncSnapshot, mode: SyncMode, ambiguousPush: Bool,
                           timeout: TimeInterval) async throws -> RepositorySyncResult {
        let repository = snapshot.repository
        func skip(_ reason: SyncSkipReason) -> RepositorySyncResult {
            .init(repository: repository, outcome: .skipped, reason: reason, fetched: true)
        }
        let current = try await status(repository)
        guard current.branch == snapshot.branch, try await headOID(repository) == snapshot.head,
              let upstream = try? await upstreamTarget(branch: snapshot.branch, repo: repository),
              upstream == snapshot.upstream,
              try await remoteIdentity(upstream.remote, repo: repository, push: false) == snapshot.fetchIdentity,
              try await fetchSpecs(upstream.remote, repo: repository) == snapshot.fetchSpecs,
              try await uploadPackCommand(upstream.remote, repo: repository) == snapshot.uploadPack,
              try await remoteCommand(upstream.remote, key: "receivepack", repo: repository) == snapshot.receivePack,
              try await fetchOptions(upstream.remote, repo: repository) == snapshot.fetchOptions,
              try await remoteIdentity(upstream.remote, repo: repository) + "\0" + upstream.ref == snapshot.pushIdentity else {
            return skip(.checkoutChanged)
        }
        guard !current.operationInProgress else { return skip(.busy) }
        guard current.changedFiles == 0, !(try await hasDirtySubmodule(repository)) else { return skip(.localChanges) }
        guard upstream.remote != "." else { return skip(.localUpstream) }
        let target = try await run(["rev-parse", "--verify", "--end-of-options", "\(upstream.trackingRef)^{commit}"], at: repository.path)
        let upstreamOID = String(decoding: target.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let counts = try await run(["rev-list", "--left-right", "--count", "\(snapshot.head)...\(upstreamOID)"], at: repository.path)
        let values = String(decoding: counts.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard values.count == 2 else { throw GitClientError.invalidData("Could not compare the checkout with its upstream.") }
        let ahead = values[0], behind = values[1]
        if ahead > 0 && behind > 0 { return skip(.diverged) }
        switch mode {
        case .background(autoPull: true):
            guard let defaultBranch = current.defaultBranch else { return skip(.unknownDefaultBranch) }
            guard current.branch == defaultBranch else { return skip(.featureBranch) }
            guard ahead == 0 else { return skip(.outgoingCommits) }
            guard behind > 0 else { return .init(repository: repository, outcome: .upToDate, fetched: true) }
        case .pushEligible:
            guard try await remoteIdentity(upstream.remote, repo: repository, push: false) + "\0" + upstream.ref == snapshot.pushIdentity else {
                return .init(repository: repository, outcome: .skipped, reason: .remoteCheckFailed,
                             message: "Push destination differs from the fetched remote or has multiple URLs.", fetched: true)
            }
            guard !ambiguousPush else { return skip(.ambiguousPushTarget) }
            guard behind == 0 else { return skip(.incomingCommits) }
            guard ahead > 0 else { return .init(repository: repository, outcome: .upToDate, fetched: true) }
        case .background(autoPull: false):
            return .init(repository: repository, outcome: .upToDate, message: "Fetched", fetched: true)
        }
        try Task.checkCancellation()
        try await validateSyncTransport(upstream.remote, repo: repository)
        let final = try await status(repository)
        guard final.branch == snapshot.branch, try await headOID(repository) == snapshot.head,
              let finalUpstream = try? await upstreamTarget(branch: snapshot.branch, repo: repository),
              finalUpstream == upstream,
              try await remoteIdentity(upstream.remote, repo: repository, push: false) == snapshot.fetchIdentity,
              try await fetchSpecs(upstream.remote, repo: repository) == snapshot.fetchSpecs,
              try await uploadPackCommand(upstream.remote, repo: repository) == snapshot.uploadPack,
              try await remoteCommand(upstream.remote, key: "receivepack", repo: repository) == snapshot.receivePack,
              try await fetchOptions(upstream.remote, repo: repository) == snapshot.fetchOptions,
              try await remoteIdentity(upstream.remote, repo: repository) + "\0" + upstream.ref == snapshot.pushIdentity else {
            return skip(.checkoutChanged)
        }
        guard !final.operationInProgress else { return skip(.busy) }
        guard final.changedFiles == 0, !(try await hasDirtySubmodule(repository)) else { return skip(.localChanges) }
        try Task.checkCancellation()
        switch mode {
        case .background:
            guard final.defaultBranch == snapshot.branch else { return skip(.checkoutChanged) }
            _ = try await run(["-c", "merge.autoStash=false", "merge", "--ff-only", "--no-overwrite-ignore", upstreamOID],
                              at: repository.path, cancellationSensitive: false)
        case .pushEligible:
            let receiveOption = snapshot.receivePack.isEmpty ? [] : ["--receive-pack=\(snapshot.receivePack)"]
            _ = try await run(["push", "--no-force", "--no-follow-tags", "--recurse-submodules=no"] + receiveOption + ["--", snapshot.fetchIdentity,
                               "\(snapshot.head):\(upstream.ref)"], at: repository.path, timeout: timeout)
        }
        return .init(repository: repository, outcome: .updated, fetched: true)
    }

    private struct UpstreamTarget: Sendable, Equatable {
        let remote: String
        let ref: String
        let trackingRef: String
    }

    private struct StashEntry: Sendable {
        let oid: String
        let selector: String
        let subject: String
    }

    private func fastForwardPull(_ upstream: UpstreamTarget, repo: Repository) async throws {
        if upstream.remote == "." {
            _ = try await run(["-c", "merge.autoStash=false", "merge", "--ff-only", "--no-overwrite-ignore", upstream.ref], at: repo.path,
                              cancellationSensitive: false)
        } else {
            _ = try await run(["fetch", "--no-prune", "--no-prune-tags", "--", upstream.remote,
                               "\(upstream.ref):\(upstream.trackingRef)"], at: repo.path, timeout: 120)
            _ = try await run(["-c", "merge.autoStash=false", "merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"], at: repo.path,
                              cancellationSensitive: false)
        }
    }

    private func stashAndPull(_ repo: Repository,
                              onProgress: (@Sendable (GitOperationPhase) async -> Void)?) async throws {
        let initial = try await status(repo)
        guard !initial.operationInProgress else {
            throw GitClientError.operationUnavailable("Finish the current Git operation before using Stash & Pull.")
        }
        guard let branch = initial.branch else {
            throw GitClientError.operationUnavailable("Stash & Pull requires an attached local branch.")
        }
        guard initial.upstream != nil else {
            throw GitClientError.operationUnavailable("The current branch has no upstream.")
        }
        let upstream = try await upstreamTarget(branch: branch, repo: repo)
        let originalHead = try await headOID(repo)
        let marker = "Branchline Stash & Pull \(UUID().uuidString)"
        var stashOID: String?

        if initial.changedFiles > 0 {
            let dirtySubmodule = try await hasDirtySubmodule(repo)
            guard !dirtySubmodule else {
                throw GitClientError.operationUnavailable("Stash & Pull cannot safely stash changes inside a submodule. Commit or stash those submodule changes first.")
            }
            await onProgress?(.savingLocalChanges)
            try Task.checkCancellation()
            try await verifyCheckout(branch: branch, head: originalHead, repo: repo)
            do {
                _ = try await run(["stash", "push", "--include-untracked", "-m", marker], at: repo.path,
                                  cancellationSensitive: false)
            } catch {
                // A stash command can create the stash and still fail to report success.
                stashOID = try? await findOwnedStash(marker, repo: repo)?.oid
                if let stashOID {
                    throw await restoreAfterFailure(error, stashOID: stashOID, branch: branch,
                                                    expectedHead: originalHead, marker: marker, repo: repo,
                                                    onProgress: onProgress)
                }
                throw GitClientError.operationUnavailable("Stash & Pull could not confirm whether Git saved the backup (marker \(marker)). No pull was attempted. Check `git stash list` and your working tree before retrying.")
            }
            do {
                stashOID = try await findOwnedStash(marker, repo: repo)?.oid
                guard stashOID != nil else {
                    throw GitClientError.operationUnavailable("Git did not report a Stash & Pull backup for marker \(marker). No pull was attempted. Check `git stash list` and your working tree before retrying.")
                }
                let clean = try await status(repo)
                guard clean.changedFiles == 0, !clean.operationInProgress else {
                    throw GitClientError.operationUnavailable("Git could not safely stash every local change. The backup was retained.")
                }
            } catch {
                if let stashOID {
                    throw await restoreAfterFailure(error, stashOID: stashOID, branch: branch,
                                                    expectedHead: originalHead, marker: marker, repo: repo,
                                                    onProgress: onProgress)
                }
                throw GitClientError.operationUnavailable("Git may have saved your changes, but Stash & Pull could not verify the backup (marker \(marker)). No pull was attempted. Check `git stash list` and your working tree before retrying.")
            }
        }

        await onProgress?(.fetching)
        do {
            if upstream.remote != "." {
                _ = try await run(["fetch", "--no-prune", "--no-prune-tags", "--", upstream.remote,
                                   "\(upstream.ref):\(upstream.trackingRef)"], at: repo.path, timeout: 120)
            }
            try Task.checkCancellation()
        } catch {
            if let stashOID {
                throw await restoreAfterFailure(error, stashOID: stashOID, branch: branch,
                                                expectedHead: originalHead, marker: marker, repo: repo,
                                                onProgress: onProgress)
            }
            throw error
        }

        await onProgress?(.pulling)
        let expectedHead: String
        do {
            let target = upstream.remote == "." ? upstream.ref : upstream.trackingRef
            let targetCommit = try await run(["rev-parse", "--verify", "--end-of-options", "\(target)^{commit}"],
                                             at: repo.path, cancellationSensitive: false)
            expectedHead = String(decoding: targetCommit.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expectedHead.isEmpty else { throw GitClientError.operationUnavailable("The upstream target is not a commit.") }
            try await verifyCheckout(branch: branch, head: originalHead, repo: repo)
        } catch {
            if let stashOID {
                throw await restoreAfterFailure(error, stashOID: stashOID, branch: branch,
                                                expectedHead: originalHead, marker: marker, repo: repo,
                                                onProgress: onProgress)
            }
            throw error
        }
        do {
            try Task.checkCancellation()
            _ = try await run(["-c", "merge.autoStash=false", "merge", "--ff-only", "--no-overwrite-ignore", expectedHead], at: repo.path,
                              cancellationSensitive: false)
        } catch {
            if let stashOID {
                throw await restoreAfterFailure(error, stashOID: stashOID, branch: branch,
                                                expectedHead: originalHead, marker: marker, repo: repo,
                                                onProgress: onProgress)
            }
            throw error
        }

        let actualHead: String
        do {
            actualHead = try await headOID(repo)
            guard actualHead == originalHead || actualHead == expectedHead else {
                throw GitClientError.operationUnavailable("The checked out commit changed unexpectedly during Stash & Pull.")
            }
            try await verifyCheckout(branch: branch, head: actualHead, repo: repo)
        } catch {
            if let stashOID { throw stashRecoveryError(error, oid: stashOID, marker: marker) }
            throw error
        }

        guard let stashOID else { return }
        await onProgress?(.restoringLocalChanges)
        do {
            try await verifyCheckout(branch: branch, head: actualHead, repo: repo)
            _ = try await run(["stash", "apply", "--index", stashOID], at: repo.path, cancellationSensitive: false)
        } catch {
            throw stashRecoveryError(error, oid: stashOID, marker: marker)
        }

        await onProgress?(.cleaningUp)
        do {
            try await dropOwnedStash(marker, oid: stashOID, repo: repo)
        } catch {
            throw GitClientError.operationUnavailable("Your changes were restored, but the Stash & Pull backup could not be removed. It remains in the stash list (\(stashOID)).")
        }
    }

    private func restoreAfterFailure(_ originalError: Error, stashOID: String, branch: String,
                                     expectedHead: String, marker: String, repo: Repository,
                                     onProgress: (@Sendable (GitOperationPhase) async -> Void)?) async -> Error {
        await onProgress?(.restoringLocalChanges)
        do {
            try await verifyCheckout(branch: branch, head: expectedHead, repo: repo)
            _ = try await run(["stash", "apply", "--index", stashOID], at: repo.path, cancellationSensitive: false)
        } catch {
            return stashRecoveryError(error, oid: stashOID, marker: marker)
        }
        do {
            await onProgress?(.cleaningUp)
            try await dropOwnedStash(marker, oid: stashOID, repo: repo)
            return originalError
        } catch {
            return GitClientError.operationUnavailable("\(originalError.localizedDescription) Your local changes were restored; the backup was retained (\(stashOID), \(marker)) because Git could not safely remove it.")
        }
    }

    private func dropOwnedStash(_ marker: String, oid: String, repo: Repository) async throws {
        guard let entry = try await findOwnedStash(marker, repo: repo), entry.oid == oid else {
            throw GitClientError.operationUnavailable("Git could not verify the owned backup entry.")
        }
        _ = try await run(["stash", "drop", entry.selector], at: repo.path, cancellationSensitive: false)
    }

    private func stashRecoveryError(_ error: Error, oid: String, marker: String) -> GitClientError {
        .operationUnavailable("Could not safely restore your local changes (\(error.localizedDescription)). The backup was kept: \(oid) (\(marker)). Recover it with `git stash apply --index \(oid)` after returning to the expected branch and commit.")
    }

    private func verifyCheckout(branch: String, head: String, repo: Repository) async throws {
        let actualBranch = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: repo.path,
                                         allowFailure: true, cancellationSensitive: false)
        let name = String(decoding: actualBranch.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualBranch.status == 0, name == branch, try await headOID(repo) == head else {
            throw GitClientError.operationUnavailable("The checked out branch or commit changed during Stash & Pull.")
        }
    }

    private func headOID(_ repo: Repository) async throws -> String {
        let output = try await run(["rev-parse", "--verify", "HEAD^{commit}"], at: repo.path, cancellationSensitive: false)
        let oid = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else { throw GitClientError.operationUnavailable("HEAD is not a commit.") }
        return oid
    }

    private func commonDirectoryPath(_ repo: Repository) async throws -> String {
        let output = try await run(["rev-parse", "--git-common-dir"], at: repo.path)
        var raw = String(decoding: output.stdout, as: UTF8.self)
        if raw.hasSuffix("\n") { raw.removeLast() }
        guard !raw.isEmpty else { throw GitClientError.operationUnavailable("Could not identify the repository's shared Git directory.") }
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(fileURLWithPath: repo.path).appendingPathComponent(raw)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func findOwnedStash(_ marker: String, repo: Repository) async throws -> StashEntry? {
        let output = try await run(["stash", "list", "--format=%H%x00%gd%x00%gs"], at: repo.path,
                                   cancellationSensitive: false)
        let text = String(decoding: output.stdout, as: UTF8.self)
        let entries = text.split(whereSeparator: \.isNewline).compactMap { line -> StashEntry? in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[2].hasSuffix(": \(marker)") else { return nil }
            return StashEntry(oid: fields[0], selector: fields[1], subject: fields[2])
        }
        guard entries.count <= 1 else {
            throw GitClientError.operationUnavailable("Git found more than one backup entry for this Stash & Pull operation.")
        }
        return entries.first
    }

    private func hasDirtySubmodule(_ repo: Repository) async throws -> Bool {
        let output = try await run(["status", "--porcelain=v2", "-z", "--branch", "--ignore-submodules=none", "--untracked-files=all"], at: repo.path)
        for record in output.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard let text = String(data: Data(record), encoding: .utf8),
                  text.hasPrefix("1 ") || text.hasPrefix("2 ") else { continue }
            let fields = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            if fields.count > 2, fields[2].hasPrefix("S"), fields[2] != "S..." { return true }
        }
        return false
    }

    private func readRefs(_ repo: Repository, includeRemotes: Bool) async throws -> [GitRef] {
        let headBranch = try await run(["symbolic-ref", "--quiet", "HEAD"], at: repo.path, allowFailure: true)
        let headRef = String(decoding: headBranch.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBranch = headBranch.status == 0 && headRef.hasPrefix("refs/heads/")
            ? String(headRef.dropFirst("refs/heads/".count)) : nil
        let defaultBranch = try await defaultBranch(repo, currentBranch: currentBranch)
        let format = "%(refname)%00%(objectname)%00%(*objectname)"
        let output = try await run(["for-each-ref", "--format=\(format)"], at: repo.path)
        var refs: [GitRef] = []
        for line in String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let values = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard values.count >= 3 else { continue }
            let fullName = values[0]
            if fullName.hasPrefix("refs/remotes/"), !includeRemotes { continue }
            let name: String
            let kind: GitRef.Kind
            if fullName.hasPrefix("refs/heads/") { kind = .localBranch; name = String(fullName.dropFirst("refs/heads/".count)) }
            else if fullName.hasPrefix("refs/remotes/") { kind = .remoteBranch; name = String(fullName.dropFirst("refs/remotes/".count)) }
            else if fullName.hasPrefix("refs/tags/") { kind = .tag; name = String(fullName.dropFirst("refs/tags/".count)) }
            else { continue }
            let isDefault = (kind == .localBranch && name == defaultBranch?.name) ||
                (kind == .remoteBranch && fullName == defaultBranch?.fullName)
            refs.append(GitRef(name: name, fullName: fullName, target: values[2].isEmpty ? values[1] : values[2],
                               kind: kind, isDefaultBranch: isDefault))
        }
        let head = try await run(["rev-parse", "--verify", "HEAD"], at: repo.path, allowFailure: true)
        if head.status == 0 {
            let target = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            refs.append(GitRef(name: "HEAD", fullName: "HEAD", target: target, kind: .head))
        }
        return refs
    }

    private struct DefaultBranch: Sendable {
        let name: String
        let fullName: String
    }

    private func defaultBranchName(_ repo: Repository, currentBranch: String?) async throws -> String? {
        try await defaultBranch(repo, currentBranch: currentBranch)?.name
    }

    private func defaultBranch(_ repo: Repository, currentBranch: String?) async throws -> DefaultBranch? {
        let format = "%(refname)%00%(objectname)%00%(*objectname)%00%(symref)"
        let output = try await run(["for-each-ref", "--format=\(format)", "refs/remotes"], at: repo.path)
        var remoteHeads: [(remote: String, branch: String, fullName: String)] = []
        var branchRefs: Set<String> = []
        let records = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map {
            $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        }
        for values in records where values.count >= 1 {
            let fullName = values[0]
            if fullName.hasPrefix("refs/remotes/") { branchRefs.insert(fullName) }
        }
        for values in records {
            guard values.count >= 4 else { continue }
            let fullName = values[0]
            guard fullName.hasPrefix("refs/remotes/"), fullName.hasSuffix("/HEAD"), !values[3].isEmpty else { continue }
            let remote = String(fullName.dropFirst("refs/remotes/".count).dropLast("/HEAD".count))
            let target = values[3]
            let prefix = "refs/remotes/\(remote)/"
            guard target.hasPrefix(prefix) else { continue }
            let branch = String(target.dropFirst(prefix.count))
            guard !branch.isEmpty, !branch.contains(".."), !branch.hasSuffix("."), !branch.hasPrefix("-") else { continue }
            let targetRef = prefix + branch
            guard branchRefs.contains(targetRef) else { continue }
            let resolved = try await run(["rev-parse", "--verify", "--end-of-options", "\(targetRef)^{commit}"], at: repo.path, allowFailure: true)
            guard resolved.status == 0 else { continue }
            remoteHeads.append((remote, branch, fullName))
        }

        if let origin = remoteHeads.first(where: { $0.remote == "origin" }) {
            return DefaultBranch(name: origin.branch, fullName: "refs/remotes/origin/\(origin.branch)")
        }
        if let currentBranch {
            let tracking = try await run(["config", "--null", "--get", "branch.\(currentBranch).remote"], at: repo.path, allowFailure: true)
            if tracking.status == 0 {
                let remote = String(decoding: tracking.stdout, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0\n\r"))
                if let currentRemoteHead = remoteHeads.first(where: { $0.remote == remote }) {
                    return DefaultBranch(name: currentRemoteHead.branch, fullName: "refs/remotes/\(remote)/\(currentRemoteHead.branch)")
                }
            }
        }
        let targets = Set(remoteHeads.map(\.branch))
        guard targets.count == 1, let name = targets.first,
              let agreeingHead = remoteHeads.first(where: { $0.branch == name }) else { return nil }
        return DefaultBranch(name: name, fullName: "refs/remotes/\(agreeingHead.remote)/\(name)")
    }

    private func readCommits(_ ids: [String], repo: Repository) async throws -> [Commit] {
        guard !ids.isEmpty else { return [] }
        let input = Data((ids.joined(separator: "\n") + "\n").utf8)
        let data = try await run(["cat-file", "--batch"], at: repo.path, input: input).stdout
        var cursor = 0
        var commits: [Commit] = []
        while cursor < data.count {
            guard let headerEnd = data[cursor...].firstIndex(of: 10) else { throw GitClientError.invalidData("Malformed cat-file response.") }
            let header = String(decoding: data[cursor..<headerEnd], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let size = Int(header[2]) else { throw GitClientError.invalidData("Malformed commit header.") }
            cursor = headerEnd + 1
            guard size >= 0, cursor + size <= data.count else { throw GitClientError.invalidData("Truncated commit body.") }
            let body = data[cursor..<(cursor + size)]
            cursor += size
            if cursor < data.count, data[cursor] == 10 { cursor += 1 }
            let commit = try parseCommit(id: String(header[0]), body: Data(body))
            commits.append(commit)
        }
        return commits
    }

    private func parseCommit(id: String, body: Data) throws -> Commit {
        guard let split = body.range(of: Data([10, 10])) else { throw GitClientError.invalidData("Commit has no message separator.") }
        let headers = String(decoding: body[..<split.lowerBound], as: UTF8.self).split(separator: "\n")
        let message = String(decoding: body[split.upperBound...], as: UTF8.self)
        func value(_ key: String) -> String? {
            headers.first(where: { $0.hasPrefix(key + " ") }).map { String($0.dropFirst(key.count + 1)) }
        }
        func identity(_ key: String) -> (String, String, Date) {
            guard let raw = value(key), let open = raw.lastIndex(of: "<"), let close = raw[open...].firstIndex(of: ">") else {
                return ("", "", .distantPast)
            }
            let name = String(raw[..<open]).trimmingCharacters(in: .whitespaces)
            let email = String(raw[raw.index(after: open)..<close])
            let rest = raw[raw.index(after: close)...].split(separator: " ")
            let timestamp = rest.first.flatMap { TimeInterval($0) } ?? 0
            return (name, email, Date(timeIntervalSince1970: timestamp))
        }
        let author = identity("author")
        let committer = identity("committer")
        let parents = headers.filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst("parent ".count)) }
        let subject = message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return Commit(id: id, parents: parents, subject: subject, message: message,
                      authorName: author.0, authorEmail: author.1, authorDate: author.2,
                      committerName: committer.0, committerEmail: committer.1, committerDate: committer.2)
    }

    private func operationInProgress(at path: String) async throws -> Bool {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-apply", "rebase-merge", "BISECT_LOG", "sequencer", "index.lock", "HEAD.lock", "packed-refs.lock", "config.lock", "shallow.lock"] {
            let output = try await run(["rev-parse", "--git-path", marker], at: path)
            let markerPath = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = markerPath.hasPrefix("/") ? markerPath : URL(fileURLWithPath: path).appendingPathComponent(markerPath).path
            if FileManager.default.fileExists(atPath: resolved) { return true }
        }
        return false
    }

    private func acquireMutation(for path: String) async throws {
        try Task.checkCancellation()
        if mutations.insert(path).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                mutationWaiters[path, default: []].append(MutationWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelMutationWaiter(id, for: path) }
        }
        if Task.isCancelled {
            releaseMutation(for: path)
            throw CancellationError()
        }
    }

    private func cancelMutationWaiter(_ id: UUID, for path: String) {
        guard var waiters = mutationWaiters[path], let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        mutationWaiters[path] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseMutation(for path: String) {
        if var waiters = mutationWaiters[path], !waiters.isEmpty {
            let next = waiters.removeFirst()
            mutationWaiters[path] = waiters.isEmpty ? nil : waiters
            next.continuation.resume()
        } else { mutations.remove(path) }
    }

    private func upstreamTarget(branch: String, repo: Repository) async throws -> UpstreamTarget {
        let output = try await run(["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)", "refs/heads/\(branch)"], at: repo.path)
        let fields = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\0", omittingEmptySubsequences: false)
        if fields.count >= 3, !fields[0].isEmpty, fields[1].hasPrefix("refs/heads/"), fields[2].hasPrefix("refs/") {
            return UpstreamTarget(remote: String(fields[0]), ref: String(fields[1]), trackingRef: String(fields[2]))
        }
        let remoteOutput = try await run(["config", "--get", "branch.\(branch).remote"], at: repo.path, allowFailure: true)
        let mergeOutput = try await run(["config", "--get-all", "branch.\(branch).merge"], at: repo.path, allowFailure: true)
        let remote = String(decoding: remoteOutput.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let merges = String(decoding: mergeOutput.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard !remote.isEmpty, merges.count == 1, let ref = merges.first, ref.hasPrefix("refs/heads/") else {
            throw GitClientError.operationUnavailable("The current branch has no supported upstream branch.")
        }
        let tracking = remote == "." ? ref : "refs/remotes/\(remote)/\(ref.dropFirst("refs/heads/".count))"
        let valid = try await run(["check-ref-format", tracking], at: repo.path, allowFailure: true)
        guard valid.status == 0 else { throw GitClientError.operationUnavailable("The upstream tracking reference is unsupported.") }
        return UpstreamTarget(remote: remote, ref: ref, trackingRef: tracking)
    }

    private func run(_ arguments: [String], at path: String, input: Data? = nil, allowFailure: Bool = false,
                     cancellationSensitive: Bool = true, timeout: TimeInterval? = nil) async throws -> GitOutput {
        if cancellationSensitive { try Task.checkCancellation() }
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = arguments
                    process.currentDirectoryURL = URL(fileURLWithPath: path)
                    var environment = ProcessInfo.processInfo.environment
                    environment["GIT_TERMINAL_PROMPT"] = "0"
                    environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oNumberOfPasswordPrompts=0"
                    environment["GIT_ASKPASS"] = "/usr/bin/false"
                    environment["SSH_ASKPASS"] = "/usr/bin/false"
                    environment["GCM_INTERACTIVE"] = "Never"
                    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX"] {
                        environment.removeValue(forKey: key)
                    }
                    process.environment = environment
                    let out = Pipe(), err = Pipe(), stdin = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    process.standardInput = stdin
                    let group = DispatchGroup()
                    group.enter()
                    process.terminationHandler = { _ in group.leave() }
                    let timer = timeout.map { interval in
                        let timer = DispatchSource.makeTimerSource()
                        timer.schedule(deadline: .now() + max(0, interval))
                        timer.setEventHandler { running.terminate(timedOut: true) }
                        timer.resume()
                        return timer
                    }
                    do {
                        try process.run()
                        running.install(process)
                        let buffers = ProcessBuffers()
                        group.enter()
                        DispatchQueue.global().async { buffers.setStdout(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                        group.enter()
                        DispatchQueue.global().async { buffers.setStderr(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                        defer { try? stdin.fileHandleForWriting.close() }
                        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
                        try stdin.fileHandleForWriting.close()
                        group.notify(queue: .global(qos: .userInitiated)) {
                            timer?.cancel()
                            running.finish()
                            let output = buffers.output(status: process.terminationStatus)
                            if running.didTimeOut {
                                continuation.resume(throwing: GitClientError.operationUnavailable("Git network operation timed out. Check the remote state before retrying."))
                            } else if running.wasCancelled { continuation.resume(throwing: CancellationError()) }
                            else if !allowFailure && output.status != 0 { continuation.resume(throwing: self.commandError(output, arguments: arguments)) }
                            else { continuation.resume(returning: output) }
                        }
                    } catch {
                        timer?.cancel()
                        if process.isRunning {
                            running.terminate()
                            process.waitUntilExit()
                        }
                        running.finish()
                        continuation.resume(throwing: running.wasCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            if cancellationSensitive { running.terminate() }
        }
    }

    private nonisolated func commandError(_ output: GitOutput, arguments: [String]) -> GitClientError {
        let message = Self.sanitize(String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        return .commandFailed(arguments: arguments, status: output.status, message: message)
    }

    private nonisolated static func sanitize(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?:https?|ssh)://[^\s<>]+"#, options: [.caseInsensitive]) else { return message }
        let nsMessage = message as NSString
        let matches = regex.matches(in: message, range: NSRange(location: 0, length: nsMessage.length))
        var result = message
        for match in matches.reversed() {
            let raw = nsMessage.substring(with: match.range)
            guard var components = URLComponents(string: raw) else { continue }
            if components.user != nil || components.password != nil {
                components.user = components.user == nil ? nil : "[redacted]"
                components.password = components.password == nil ? nil : "[redacted]"
            }
            if let query = components.queryItems {
                let sensitive = ["token", "access_token", "auth", "password", "key", "signature", "secret"]
                components.queryItems = query.map { item in
                    sensitive.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "[redacted]") : item
                }
            }
            if let safe = components.string, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: safe) }
        }
        return result
    }
}
