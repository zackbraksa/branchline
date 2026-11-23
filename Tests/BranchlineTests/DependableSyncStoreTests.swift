import Foundation
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    @MainActor
    struct DependableSyncStoreTests {
        @Test func autoPullPreferenceDefaultsOffAndSurvivesFetchPause() throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let (store, defaults, suite) = try fixture.store([])
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(!store.autoPullEnabled)
            store.setAutoPullEnabled(true)
            store.setAutoFetchEnabled(false)
            let restored = BranchlineStore(arguments: [], catalogStore: RepositoryCatalogStore(defaults: defaults))
            #expect(restored.autoPullEnabled)
            #expect(!restored.autoFetchEnabled)
        }

        @Test func backgroundPullUpdatesSavedDefaultCheckoutWithoutTouchingDiscoveredWorktree() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.repository(0)
            let worktreeURL = fixture.root.appendingPathComponent("linked")
            try fixture.git(["worktree", "add", "-b", "feature", worktreeURL.path], at: repository.url)
            try fixture.git(["branch", "--set-upstream-to", "origin/main", "feature"], at: repository.url)
            let worktreeHead = try fixture.git(["rev-parse", "HEAD"], at: worktreeURL)
            try fixture.advanceRemote(repository)
            let (store, defaults, suite) = try fixture.store([repository.model])
            defer { store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { store.lastAutoFetchDate != nil && !store.isAutoFetching })
            #expect(try fixture.git(["rev-parse", "HEAD"], at: repository.url) == worktreeHead)
            #expect(store.repositoryStatuses[repository.model.path]?.behind == 1)
            store.stopBackgroundAutoFetch()
            store.setAutoPullEnabled(true)
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { store.backgroundSyncMessages[repository.model.path]?.contains("Updated") == true && !store.isAutoFetching })
            #expect(try fixture.git(["rev-parse", "HEAD"], at: repository.url) == fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote))
            #expect(try fixture.git(["rev-parse", "HEAD"], at: worktreeURL) == worktreeHead)
            #expect(store.backgroundSyncMessages[worktreeURL.resolvingSymlinksInPath().path] == nil)
            #expect(!store.showsOperationResults)
        }

        @Test func laterLinkedCheckoutResultDoesNotClearEarlierPullFailure() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.repository(0)
            let worktreeURL = fixture.root.appendingPathComponent("linked")
            try fixture.git(["worktree", "add", "-b", "feature", worktreeURL.path], at: repository.url)
            try fixture.git(["branch", "--set-upstream-to", "origin/main", "feature"], at: repository.url)
            let exclude = repository.url.appendingPathComponent(".git/info/exclude")
            try Data("protected.txt\n".utf8).write(to: exclude)
            let protected = repository.url.appendingPathComponent("protected.txt")
            try Data("local ignored work".utf8).write(to: protected)
            try Data("remote file".utf8).write(to: repository.seed.appendingPathComponent("protected.txt"))
            try fixture.git(["add", "protected.txt"], at: repository.seed)
            try fixture.commit("incoming file", at: repository.seed)
            try fixture.git(["push", "origin", "main"], at: repository.seed)
            let child = Repository(path: worktreeURL.resolvingSymlinksInPath().path)
            let (store, defaults, suite) = try fixture.store([repository.model, child])
            defer { store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            store.setAutoPullEnabled(true)
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { store.lastAutoFetchDate != nil && !store.isAutoFetching })
            #expect(store.backgroundFetchErrors[repository.model.path] != nil)
            #expect(store.backgroundFetchErrors[child.path] == nil)
            #expect(store.backgroundSyncMessages[child.path] == "Feature branch")
            #expect(try String(contentsOf: protected, encoding: .utf8) == "local ignored work")
        }

        @Test func disablingAutoPullDuringFetchCancelsPendingWrite() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.repository(0)
            let originalHead = try fixture.git(["rev-parse", "HEAD"], at: repository.url)
            try fixture.advanceRemote(repository)
            let helper = fixture.root.appendingPathComponent("held-upload")
            try Data("#!/bin/sh\ntouch '\(fixture.marker(0).path)'\nwhile [ ! -e '\(fixture.gate(0).path)' ]; do sleep 0.02; done\nexec git-upload-pack \"$@\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "remote.origin.uploadpack", helper.path], at: repository.url)
            let (store, defaults, suite) = try fixture.store([repository.model])
            defer { try? Data().write(to: fixture.gate(0)); store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            store.setAutoPullEnabled(true)
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { fixture.started(0) })
            store.setAutoPullEnabled(false)
            try Data().write(to: fixture.gate(0))
            #expect(await waitUntil { store.lastAutoFetchDate != nil && !store.isAutoFetching })
            #expect(try fixture.git(["rev-parse", "HEAD"], at: repository.url) == originalHead)
            #expect(store.repositoryStatuses[repository.model.path]?.behind == 1)
            #expect(!store.autoPullEnabled)
            #expect(!store.showsOperationResults)
        }

        @Test func backgroundPassCapturesParallelLimit() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repositories = try (0..<3).map { try fixture.repository($0) }
            for (index, repository) in repositories.enumerated() {
                let helper = fixture.root.appendingPathComponent("upload-\(index)")
                let script = "#!/bin/sh\ntouch '\(fixture.marker(index).path)'\nwhile [ ! -e '\(fixture.gate(index).path)' ]; do sleep 0.02; done\nexec git-upload-pack \"$@\"\n"
                try Data(script.utf8).write(to: helper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
                try fixture.git(["config", "remote.origin.uploadpack", helper.path], at: repository.url)
            }
            let (store, defaults, suite) = try fixture.store(repositories.map(\.model))
            defer {
                for index in 0..<3 { try? Data().write(to: fixture.gate(index)) }
                store.stopBackgroundAutoFetch()
                defaults.removePersistentDomain(forName: suite)
            }
            store.setManualOperationConcurrency(2)
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { fixture.started(0) && fixture.started(1) })
            #expect(!fixture.started(2))
            store.setManualOperationConcurrency(1)
            try Data().write(to: fixture.gate(0))
            #expect(await waitUntil { fixture.started(2) })
            try Data().write(to: fixture.gate(1))
            try Data().write(to: fixture.gate(2))
            #expect(await waitUntil { store.lastAutoFetchDate != nil && !store.isAutoFetching })
            #expect(store.backgroundFetchErrors.isEmpty)
        }

        @Test func pushEligibleSkipsDirtyAndRetryOnlyRechecksFailedSnapshotMembers() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repositories = try (0..<3).map { try fixture.repository($0) }
            for repository in repositories { try fixture.commit("outgoing", at: repository.url) }
            try Data("unfinished".utf8).write(to: repositories[1].url.appendingPathComponent("dirty.txt"))
            try fixture.git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").path], at: repositories[2].url)
            let (store, defaults, suite) = try fixture.store(repositories.map(\.model))
            defer { defaults.removePersistentDomain(forName: suite) }
            store.performPushAllEligible()
            store.selectRepositories([repositories[1].model.path])
            #expect(await waitUntil { !store.isOperationRunning })
            let results = Dictionary(uniqueKeysWithValues: store.operationResults.map { ($0.id, $0) })
            #expect(results[repositories[0].model.path]?.outcome == .updated)
            #expect(results[repositories[1].model.path]?.outcome == .skipped)
            #expect(results[repositories[1].model.path]?.error == nil)
            #expect(results[repositories[2].model.path]?.outcome == .failed)
            #expect(store.canRetryFailedOperation)
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: repositories[0].remote) == fixture.git(["rev-parse", "HEAD"], at: repositories[0].url))
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: repositories[1].remote) != fixture.git(["rev-parse", "HEAD"], at: repositories[1].url))
            try FileManager.default.removeItem(at: repositories[1].url.appendingPathComponent("dirty.txt"))
            try fixture.git(["remote", "set-url", "origin", repositories[2].remote.path], at: repositories[2].url)
            store.retryFailedOperation()
            #expect(Set(store.operationRepositories.map(\.path)) == [repositories[2].model.path])
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationResults.first?.outcome == .updated)
            #expect(!store.canRetryFailedOperation)
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: repositories[1].remote) != fixture.git(["rev-parse", "HEAD"], at: repositories[1].url))
        }

        @Test func eligiblePushSkipsSameDestinationAcrossIndependentClones() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let first = try fixture.repository(0)
            let secondURL = fixture.root.appendingPathComponent("independent-clone")
            try fixture.git(["clone", first.remote.path, secondURL.path], at: fixture.root)
            try fixture.commit("first outgoing", at: first.url)
            try fixture.commit("second outgoing", at: secondURL)
            let originalRemoteHead = try fixture.git(["rev-parse", "refs/heads/main"], at: first.remote)
            let second = Repository(path: secondURL.resolvingSymlinksInPath().path)
            let (store, defaults, suite) = try fixture.store([first.model, second])
            defer { defaults.removePersistentDomain(forName: suite) }
            store.performPushAllEligible()
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationResults.count == 2)
            #expect(store.operationResults.allSatisfy { $0.outcome == .skipped && $0.displayStatus == "Multiple checkouts target the same remote branch" })
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: first.remote) == originalRemoteHead)
            #expect(!store.canRetryFailedOperation)
        }

        @Test(arguments: [false, true]) func eligibleRetryChecksNewlySavedSiblingForAmbiguousPushTarget(independentClone: Bool) async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.repository(0)
            try fixture.commit("outgoing", at: repository.url)
            let originalRemoteHead = try fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote)
            try fixture.git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").path], at: repository.url)
            let (store, defaults, suite) = try fixture.store([repository.model])
            defer { defaults.removePersistentDomain(forName: suite) }
            store.performPushAllEligible()
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.canRetryFailedOperation)
            let scanRoot = fixture.root.appendingPathComponent("checkouts")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            let linked = scanRoot.appendingPathComponent("feature")
            try fixture.git(["remote", "set-url", "origin", repository.remote.path], at: repository.url)
            if independentClone {
                try fixture.git(["clone", repository.remote.path, linked.path], at: fixture.root)
                try fixture.commit("second outgoing", at: linked)
            } else {
                try fixture.git(["worktree", "add", "-b", "feature", linked.path], at: repository.url)
                try fixture.git(["branch", "--set-upstream-to", "origin/main", "feature"], at: repository.url)
            }
            await store.scanFolder(scanRoot)
            #expect(store.repositories.count == 2)
            store.retryFailedOperation()
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationRepositories.map(\.path) == [repository.model.path])
            #expect(store.operationResults.first?.outcome == .skipped)
            #expect(store.operationResults.first?.displayStatus == "Multiple checkouts target the same remote branch")
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote) == originalRemoteHead)
        }

        @Test func retryOfManualPushUsesFreshCleanEligibility() async throws {
            let fixture = try SyncStoreFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.repository(0)
            try fixture.commit("outgoing", at: repository.url)
            let remoteHead = try fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote)
            try fixture.git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").path], at: repository.url)
            let (store, defaults, suite) = try fixture.store([repository.model])
            defer { defaults.removePersistentDomain(forName: suite) }
            store.perform(.push)
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.canRetryFailedOperation)
            try fixture.git(["remote", "set-url", "origin", repository.remote.path], at: repository.url)
            try Data("unfinished".utf8).write(to: repository.url.appendingPathComponent("dirty.txt"))
            store.retryFailedOperation()
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationResults.first?.outcome == .skipped)
            #expect(store.operationResults.first?.displayStatus == "Local changes")
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote) == remoteHead)
        }

        @Test func typedSkippedAndCancelledResultsAreTerminalWithoutFailure() {
            let skipped = OperationResult(id: "skip", name: "skip", progress: "Skipped", error: nil, completionSummary: "Local changes", outcome: .skipped)
            #expect(skipped.isFinished && skipped.isSkipped && !skipped.isFailure)
            #expect(skipped.displayStatus == "Local changes")
            let cancelled = OperationResult(id: "cancel", name: "cancel", progress: "Cancelled", error: nil, outcome: .cancelled)
            #expect(cancelled.isFinished && cancelled.isCancelled && !cancelled.isFailure)
        }

        private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
    }
}

private struct SyncStoreFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineDependableStore-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func marker(_ index: Int) -> URL { root.appendingPathComponent("started-\(index)") }
    func gate(_ index: Int) -> URL { root.appendingPathComponent("gate-\(index)") }
    func started(_ index: Int) -> Bool { FileManager.default.fileExists(atPath: marker(index).path) }

    func repository(_ index: Int) throws -> SyncStoreRepository {
        let remote = root.appendingPathComponent("remote-\(index).git")
        let seed = root.appendingPathComponent("seed-\(index)")
        let url = root.appendingPathComponent("repo-\(index)")
        try git(["init", "--bare", "--initial-branch=main", remote.path], at: root)
        try git(["clone", remote.path, seed.path], at: root)
        try commit("base", at: seed)
        try git(["push", "-u", "origin", "main"], at: seed)
        try git(["clone", remote.path, url.path], at: root)
        return SyncStoreRepository(url: url, remote: remote, seed: seed)
    }

    func advanceRemote(_ repository: SyncStoreRepository) throws {
        try commit("incoming", at: repository.seed)
        try git(["push", "origin", "main"], at: repository.seed)
    }

    func commit(_ message: String, at url: URL) throws {
        try git(["-c", "user.name=Branchline Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", message], at: url)
    }

    @MainActor func store(_ repositories: [Repository]) throws -> (BranchlineStore, UserDefaults, String) {
        let suite = "DependableSyncStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let catalog = RepositoryCatalogStore(defaults: defaults)
        catalog.save(RepositoryCatalog(repositories: repositories, scanRoots: [], selectedRepositoryPath: repositories.first?.path))
        return (BranchlineStore(arguments: [], catalogStore: catalog, autoFetchInterval: .seconds(100)), defaults, suite)
    }

    @discardableResult func git(_ args: [String], at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output; process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DependableSyncStoreTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostic, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SyncStoreRepository {
    let url: URL
    let remote: URL
    let seed: URL
    var model: Repository { Repository(path: url.resolvingSymlinksInPath().path) }
}
