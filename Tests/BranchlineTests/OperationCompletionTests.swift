import Foundation
import Darwin
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    struct OperationCompletionTests {
        @MainActor
        @Test(arguments: [GitOperation.pull, .stashAndPull])
        func successfulPullBatchDismissesAutomatically(operation: GitOperation) async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { defaults.removePersistentDomain(forName: suite) }

            store.performBatch(operation)
            #expect(store.showsOperationResults)
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationResults.allSatisfy { $0.progress == "Done" })
            #expect(!store.showsOperationResults)
        }

        @MainActor
        @Test(arguments: [GitOperation.pull, .stashAndPull])
        func partiallyFailedPullBatchStaysVisible(operation: GitOperation) async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let other = fixture.root.appendingPathComponent("other")
            try fixture.git(["clone", repository.remote.path, other.path], at: fixture.root)
            try fixture.git(["branch", "--unset-upstream"], at: other)
            let suite = "OperationCompletionTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository.model, Repository(path: other.path)],
                                           scanRoots: [], selectedRepositoryPath: repository.path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)

            store.performBatch(operation)
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationResults.contains { $0.progress == "Done" })
            #expect(store.operationResults.contains { $0.isFailure })
            #expect(store.showsOperationResults)
        }

        @MainActor
        @Test(arguments: [GitOperation.pull, .stashAndPull])
        func cancelledPullStaysVisible(operation: GitOperation) async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { defaults.removePersistentDomain(forName: suite) }

            store.perform(operation)
            store.cancelOperation()
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationResults.allSatisfy { $0.isCancelled })
            #expect(store.showsOperationResults)
        }

        @MainActor
        @Test(arguments: [true, false])
        func completedBatchRemainsDismissibleWhileFinalRefreshIsBlocked(dismiss: Bool) async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let unrelated = fixture.root.appendingPathComponent("unrelated")
            try fixture.git(["clone", repository.remote.path, unrelated.path], at: fixture.root)
            let suite = "OperationFinalRefreshTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository.model, Repository(path: unrelated.path)],
                                           scanRoots: [], selectedRepositoryPath: repository.path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            #expect(await waitUntil { !store.commits.isEmpty && !store.isLoadingHistory })
            await store.refreshAllStatuses()
            let marker = fixture.root.appendingPathComponent("refresh-pid")
            let helper = fixture.root.appendingPathComponent("blocked-fsmonitor")
            try Data("#!/bin/sh\necho $$ > '\(marker.path)'\nexec /bin/sleep 120\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "core.fsmonitor", helper.path], at: unrelated)
            var helperPID: pid_t?
            defer {
                store.dismissOperationResults()
                store.cancelOperation()
                if let helperPID { kill(helperPID, SIGKILL) }
            }

            store.perform(.fetch)
            try #require(await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
            let rawPID = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            helperPID = Int32(rawPID)
            _ = try #require(helperPID)
            #expect(!store.isOperationRunning)
            #expect(store.operationTask == nil)
            #expect(store.operationResults.allSatisfy { $0.isFinished })
            #expect(store.showsOperationResults)

            if dismiss {
                store.dismissOperationResults()
                #expect(!store.showsOperationResults)
            } else {
                store.perform(.fetch)
                #expect(store.isOperationRunning)
            }
            try fixture.git(["config", "--unset", "core.fsmonitor"], at: unrelated)
            let pid = try #require(helperPID)
            #expect(await waitUntil { kill(pid, 0) == -1 })
            if dismiss { store.perform(.fetch) }
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationProgress[repository.path] == "Done")
            #expect(store.operationErrors.isEmpty)
            #expect(store.statusErrors[unrelated.path] == nil)
            #expect(store.showsOperationResults)
        }

        @MainActor
        @Test func cancelledBatchFinishesAndCanBeDismissed() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { defaults.removePersistentDomain(forName: suite); store.dismissOperationResults() }
            store.perform(.fetch)
            store.cancelOperation()
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationTask == nil)
            #expect(store.operationResults.allSatisfy { $0.isCancelled })
            store.dismissOperationResults()
            #expect(!store.showsOperationResults)
        }

        @MainActor
        @Test func backgroundFetchUpdatesTrackingWithoutTouchingWork() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let peer = fixture.root.appendingPathComponent("peer")
            try fixture.git(["clone", repository.remote.path, peer.path], at: fixture.root)
            try fixture.git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "remote"], at: peer)
            try fixture.git(["push", "origin", "main"], at: peer)
            try Data("staged\n".utf8).write(to: repository.url.appendingPathComponent("file.txt"))
            try fixture.git(["add", "file.txt"], at: repository.url)
            try Data("unstaged\n".utf8).write(to: repository.url.appendingPathComponent("file.txt"))
            try Data("untracked\n".utf8).write(to: repository.url.appendingPathComponent("untracked"))
            let head = try fixture.git(["rev-parse", "HEAD"], at: repository.url)
            let status = try fixture.git(["status", "--porcelain=v1"], at: repository.url)
            let index = try fixture.git(["diff", "--cached"], at: repository.url)
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            store.startBackgroundAutoFetch()
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { store.lastAutoFetchDate != nil })
            #expect(store.repositoryStatuses[repository.path]?.behind == 1)
            #expect(store.commits.contains { $0.subject == "remote" })
            #expect(try fixture.git(["rev-parse", "HEAD"], at: repository.url) == head)
            #expect(try fixture.git(["status", "--porcelain=v1"], at: repository.url) == status)
            #expect(try fixture.git(["diff", "--cached"], at: repository.url) == index)
            #expect(store.backgroundFetchErrors.isEmpty)
            let firstPass = try #require(store.lastAutoFetchDate)
            #expect(await waitUntil { (store.lastAutoFetchDate ?? firstPass) > firstPass })
            store.setAutoFetchEnabled(false)
            #expect(!RepositoryCatalogStore(defaults: defaults).load().autoFetchEnabled)
            #expect(await waitUntil { !store.isAutoFetching })
            let stoppedAt = store.lastAutoFetchDate
            try await Task.sleep(for: .milliseconds(500))
            #expect(store.lastAutoFetchDate == stoppedAt)
        }

        @MainActor
        @Test func changingIntervalReschedulesWithoutAnImmediateFetch() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let script = fixture.root.appendingPathComponent("record-upload")
            let starts = fixture.root.appendingPathComponent("starts")
            try Data("#!/bin/sh\n/usr/bin/python3 -c 'import time; print(time.time())' >> '\(starts.path)'\nexec git-upload-pack \"$@\"\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try fixture.git(["config", "remote.origin.uploadpack", script.path], at: repository.url)
            let (store, defaults, suite) = try fixture.makeStore(repository, interval: .seconds(1))
            defer { store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            func fetchStarts() -> [TimeInterval] {
                (try? String(contentsOf: starts, encoding: .utf8))?.split(separator: "\n").compactMap { Double($0) } ?? []
            }
            store.setAutoFetchIntervalMinutes(60)
            store.startBackgroundAutoFetch()
            #expect(await waitUntil(timeout: .seconds(40)) { store.lastAutoFetchDate != nil && !store.isAutoFetching })
            let first = try #require(store.lastAutoFetchDate)
            let shortenedAt = Date().timeIntervalSince1970
            store.setAutoFetchIntervalMinutes(15)
            #expect(await waitUntil(timeout: .seconds(40)) { (store.lastAutoFetchDate ?? first) > first && !store.isAutoFetching })
            let second = try #require(store.lastAutoFetchDate)
            let secondStart = try #require(fetchStarts().dropFirst().first)
            #expect(secondStart - shortenedAt >= 2.8)
            #expect(secondStart - shortenedAt < 12)

            let lengthenedAt = Date().timeIntervalSince1970
            store.setAutoFetchIntervalMinutes(60)
            try await Task.sleep(for: .seconds(4))
            let earlyStarts = fetchStarts().filter { $0 >= lengthenedAt && $0 < lengthenedAt + 11.8 }
            #expect(earlyStarts.isEmpty)
            #expect(store.lastAutoFetchDate == second || Date().timeIntervalSince1970 >= lengthenedAt + 12)

        }

        @MainActor
        @Test func changingIntervalDuringFetchLetsCurrentPassFinish() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let script = fixture.root.appendingPathComponent("upload")
            let marker = fixture.root.appendingPathComponent("started")
            let gate = fixture.root.appendingPathComponent("gate")
            try Data("#!/bin/sh\ntouch '\(marker.path)'\nwhile [ ! -e '\(gate.path)' ]; do sleep 0.05; done\nexec git-upload-pack \"$@\"\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try fixture.git(["config", "remote.origin.uploadpack", script.path], at: repository.url)
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { try? Data().write(to: gate); store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
            store.setAutoFetchIntervalMinutes(60)
            try Data().write(to: gate)
            #expect(await waitUntil { store.lastAutoFetchDate != nil })
            let first = try #require(store.lastAutoFetchDate)
            try await Task.sleep(for: .milliseconds(300))
            #expect(store.lastAutoFetchDate == first)
            #expect(store.backgroundFetchErrors.isEmpty)
        }

        @MainActor
        @Test func backgroundFailureDoesNotStopOtherRepositories() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let broken = fixture.root.appendingPathComponent("broken")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try fixture.git(["init", "-b", "main"], at: broken)
            try fixture.git(["remote", "add", "origin", fixture.root.appendingPathComponent("missing.git").path], at: broken)
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            let models = [Repository(path: broken.resolvingSymlinksInPath().path), Repository(path: repository.path)]
            let priorDate = Date(timeIntervalSince1970: 1_700_000_000)
            catalog.save(RepositoryCatalog(repositories: models, scanRoots: [], selectedRepositoryPath: repository.path, repositoryFetchDates: [models[0].path: priorDate]))
            let batchStore = BranchlineStore(arguments: [], catalogStore: catalog)
            defer { batchStore.stopBackgroundAutoFetch() }
            batchStore.startBackgroundAutoFetch()
            #expect(await waitUntil { batchStore.lastAutoFetchDate != nil })
            #expect(batchStore.backgroundFetchErrors[models[0].path] != nil)
            #expect(batchStore.repositoryFetchDates[models[0].path] == priorDate)
            #expect(batchStore.backgroundFetchErrors[repository.path] == nil)
            #expect(batchStore.repositoryStatuses[repository.path] != nil)
            #expect(batchStore.globalError == nil)
            #expect(!batchStore.showsOperationResults)
        }

        @MainActor
        @Test func manualFetchCancelsBackgroundBeforeStarting() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let helper = fixture.root.appendingPathComponent("slow-upload-pack")
            let marker = fixture.root.appendingPathComponent("started")
            try Data("#!/bin/sh\ntouch '\(marker.path)'\nexec sleep 30\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "remote.origin.uploadpack", helper.path], at: repository.url)
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { store.stopBackgroundAutoFetch(); defaults.removePersistentDomain(forName: suite) }
            store.startBackgroundAutoFetch()
            #expect(await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
            try fixture.git(["config", "remote.origin.uploadpack", "git-upload-pack"], at: repository.url)
            store.perform(.fetch)
            #expect(await waitUntil(timeout: .seconds(10)) { !store.isOperationRunning })
            #expect(store.operationProgress[repository.path] == "Done")
            #expect(store.operationErrors.isEmpty)
        }

        @MainActor
        @Test func manualBatchKeepsItsConcurrencyWhenSettingChanges() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            var models = [repository.model]
            for index in 1...2 {
                let clone = fixture.root.appendingPathComponent("clone\(index)")
                try fixture.git(["clone", repository.remote.path, clone.path], at: fixture.root)
                models.append(Repository(path: clone.resolvingSymlinksInPath().path))
            }
            for (index, model) in models.enumerated() {
                let script = fixture.root.appendingPathComponent("upload\(index)")
                let marker = fixture.root.appendingPathComponent("started\(index)")
                let gate = fixture.root.appendingPathComponent("gate\(index)")
                try Data("#!/bin/sh\ntouch '\(marker.path)'\nwhile [ ! -e '\(gate.path)' ]; do sleep 0.05; done\nexec git-upload-pack \"$@\"\n".utf8).write(to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                try fixture.git(["config", "remote.origin.uploadpack", script.path], at: URL(fileURLWithPath: model.path))
            }
            let suite = "OperationConcurrencyTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: models, scanRoots: [], selectedRepositoryPath: models[0].path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            store.setManualOperationConcurrency(2)
            store.performBatch(.fetch)
            func started(_ index: Int) -> Bool { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("started\(index)").path) }
            func release(_ index: Int) throws { try Data().write(to: fixture.root.appendingPathComponent("gate\(index)")) }
            defer { for index in 0...2 { try? release(index) }; store.cancelOperation() }
            #expect(await waitUntil { started(0) && started(1) })
            #expect(!started(2))
            store.setManualOperationConcurrency(1)
            try release(0)
            #expect(await waitUntil { started(2) })
            try release(1)
            try release(2)
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationErrors.isEmpty)
        }

        @Test func completionSummariesDescribeSyncState() {
            #expect(OperationResult.summary(
                for: .pull,
                status: RepositoryStatus(branch: "main", upstream: "origin/main", ahead: 3, behind: 0)
            ) == "Pull complete · 3 to push")
            #expect(OperationResult.summary(
                for: .pull,
                status: RepositoryStatus(branch: "main", upstream: "origin/main")
            ) == "Pull complete · up to date")
            #expect(OperationResult.summary(
                for: .fetch,
                status: RepositoryStatus(branch: "main", upstream: "origin/main", ahead: 2, behind: 4, changedFiles: 1)
            ) == "Fetch complete · 2 to push · 4 to pull · 1 local change")
            #expect(OperationResult.summary(
                for: .stashAndPull,
                status: RepositoryStatus(branch: "main")
            ) == "Stash & Pull complete · no upstream")
            #expect(OperationResult.summary(for: .pull, status: nil) == "Pull complete · status unavailable")
        }

        @Test func readableFailureTakesPriorityOverCompletionSummary() {
            let result = OperationResult(
                id: "/tmp/repo",
                name: "repo",
                progress: "Failed",
                error: "The current branch has no upstream.",
                completionSummary: "Pull complete · up to date"
            )

            #expect(result.displayStatus == "The current branch has no upstream.")
        }

        @MainActor
        @Test func completedPullShowsFreshAheadCountWithoutPushingLocalCommits() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            for index in 1...3 {
                try fixture.git(["-c", "user.name=Branchline Test", "-c", "user.email=branchline@example.test", "commit", "--allow-empty", "-m", "local \(index)"], at: repository.url)
            }
            let localHeadBefore = try fixture.git(["rev-parse", "HEAD"], at: repository.url)
            let remoteHeadBefore = try fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote)
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { defaults.removePersistentDomain(forName: suite) }

            store.perform(.pull)

            #expect(await waitUntil { !store.isOperationRunning })
            let status = try #require(store.repositoryStatuses[repository.path])
            #expect(status.ahead == 3)
            #expect(status.behind == 0)
            #expect(try fixture.git(["rev-parse", "HEAD"], at: repository.url) == localHeadBefore)
            #expect(try fixture.git(["rev-parse", "refs/heads/main"], at: repository.remote) == remoteHeadBefore)
            #expect(store.operationProgress[repository.path] == "Done")
            let result = try #require(store.operationResults.first)
            #expect(result.id == repository.path)
            #expect(result.displayStatus == "Pull complete · 3 to push")
            let fetchedAt = try #require(store.repositoryFetchDates[repository.path])
            #expect(RepositoryCatalogStore(defaults: defaults).load().repositoryFetchDates[repository.path] == fetchedAt)

            store.perform(.push)
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.repositoryFetchDates[repository.path] == fetchedAt)
            await store.refreshStatus(for: repository.model)
            #expect(store.repositoryFetchDates[repository.path] == fetchedAt)
        }

        @MainActor
        @Test func removingRepositoryRemovesItsFetchDate() async throws {
            let fixture = try CompletionFixture()
            defer { fixture.cleanUp() }
            let repository = try fixture.makeRepository()
            let (store, defaults, suite) = try fixture.makeStore(repository)
            defer { defaults.removePersistentDomain(forName: suite) }
            store.perform(.fetch)
            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.repositoryFetchDates[repository.path] != nil)

            store.removeRepository(repository.model)

            #expect(store.repositoryFetchDates[repository.path] == nil)
            #expect(RepositoryCatalogStore(defaults: defaults).load().repositoryFetchDates[repository.path] == nil)
        }
    }
}

private struct CompletionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineOperationCompletion-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func makeRepository() throws -> CompletionRepository {
        let remote = root.appendingPathComponent("remote.git")
        let working = root.appendingPathComponent("repo")
        try git(["init", "--bare", "--initial-branch=main", remote.path], at: root)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: working)
        try git(["config", "user.name", "Branchline Test"], at: working)
        try git(["config", "user.email", "branchline@example.test"], at: working)
        try Data("base\n".utf8).write(to: working.appendingPathComponent("file.txt"))
        try git(["add", "file.txt"], at: working)
        try git(["commit", "-m", "base"], at: working)
        try git(["remote", "add", "origin", remote.path], at: working)
        try git(["push", "-u", "origin", "main"], at: working)
        return CompletionRepository(url: working, remote: remote)
    }

    @MainActor
    func makeStore(_ repository: CompletionRepository, interval: Duration = .milliseconds(100)) throws -> (BranchlineStore, UserDefaults, String) {
        let suite = "OperationCompletionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = Repository(path: repository.path)
        let catalog = RepositoryCatalogStore(defaults: defaults)
        catalog.save(RepositoryCatalog(repositories: [model], scanRoots: [], selectedRepositoryPath: model.path))
        return (BranchlineStore(arguments: [], catalogStore: catalog, autoFetchInterval: interval), defaults, suite)
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "OperationCompletionTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)]
            )
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CompletionRepository {
    let url: URL
    let remote: URL
    var path: String { url.resolvingSymlinksInPath().path }
    var model: Repository { Repository(path: path) }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(20), condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
