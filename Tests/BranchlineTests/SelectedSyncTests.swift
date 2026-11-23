import Foundation
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    @MainActor
    struct SelectedSyncTests {
        @Test func selectedPullUpdatesOnlySelectedRepositoriesAndSnapshotsSelection() async throws {
            let fixture = try SyncFixture()
            defer { fixture.cleanUp() }
            let repositories = try fixture.repositories(count: 3)
            for repository in repositories { try fixture.advanceRemote(for: repository) }
            let (store, defaults, suite) = try fixture.makeStore(repositories)
            defer { defaults.removePersistentDomain(forName: suite) }

            let selected = Set(repositories.prefix(2).map(\.path))
            store.selectRepositories(selected)
            store.perform(.pull)
            #expect(Set(store.operationProgress.keys) == selected)
            store.selectRepositories([repositories[2].path])

            #expect(await waitUntil { !store.isOperationRunning })
            for repository in repositories.prefix(2) {
                #expect(try fixture.head(of: repository) == fixture.remoteHead(of: repository))
                #expect(store.operationProgress[repository.path] == "Done")
            }
            #expect(try fixture.head(of: repositories[2]) != fixture.remoteHead(of: repositories[2]))
            #expect(store.operationProgress[repositories[2].path] == nil)
        }

        @Test func selectedPushWritesOnlySelectedRepositoriesAndFailureDoesNotStopOtherSelected() async throws {
            let fixture = try SyncFixture()
            defer { fixture.cleanUp() }
            let repositories = try fixture.repositories(count: 3)
            for repository in repositories { try fixture.addLocalCommit(to: repository) }
            // Break one selected repository's configured upstream. The other selected
            // repository must still push, and the unselected repository must not.
            try fixture.git(["config", "branch.main.remote", "missing"], at: repositories[0].url)
            let (store, defaults, suite) = try fixture.makeStore(repositories)
            defer { defaults.removePersistentDomain(forName: suite) }

            let selected = Set(repositories.prefix(2).map(\.path))
            store.selectRepositories(selected)
            store.perform(.push)
            #expect(Set(store.operationProgress.keys) == selected)

            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationProgress[repositories[0].path] == "Failed")
            #expect(store.operationErrors[repositories[0].path] != nil)
            #expect(store.operationProgress[repositories[1].path] == "Done")
            #expect(try fixture.remoteHead(of: repositories[1]) == fixture.head(of: repositories[1]))
            #expect(try fixture.remoteHead(of: repositories[2]) != fixture.head(of: repositories[2]))
            #expect(store.operationProgress[repositories[2].path] == nil)
        }

        @Test func selectedSyncWithNoSelectionIsNoOp() throws {
            let fixture = try SyncFixture()
            defer { fixture.cleanUp() }
            let repositories = try fixture.repositories(count: 1)
            let (store, defaults, suite) = try fixture.makeStore(repositories)
            defer { defaults.removePersistentDomain(forName: suite) }
            store.selectRepositories([])

            store.perform(.pull)

            #expect(!store.isOperationRunning)
            #expect(store.operationProgress.isEmpty)
        }

        @Test func savedRootScanPublishesScanningStateAndClearsItOnSuccessAndFailure() async throws {
            let fixture = try SyncFixture()
            defer { fixture.cleanUp() }
            let scanRoot = fixture.root.appendingPathComponent("scan")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            // Enough real repositories make startup discovery spend time in its async
            // Git validation path, so the published state is observed while scanning.
            let scanned = try fixture.repositories(count: 12, under: scanRoot)
            let (store, defaults, suite) = try fixture.makeStore([], scanRoots: [scanRoot])
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil { store.isScanningFolders })
            #expect(await waitUntil {
                Set(store.repositories.map(\.path)) == Set(scanned.map(\.path)) && !store.isScanningFolders
            })

            let missingRoot = fixture.root.appendingPathComponent("missing")
            let (failedStore, failedDefaults, failedSuite) = try fixture.makeStore([], scanRoots: [missingRoot])
            defer { failedDefaults.removePersistentDomain(forName: failedSuite) }
            #expect(await waitUntil { failedStore.isScanningFolders || failedStore.globalError != nil })
            #expect(await waitUntil { !failedStore.isScanningFolders && failedStore.globalError != nil })
        }
    }
}

private struct SyncFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineSelectedSync-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func repositories(count: Int, under parent: URL? = nil) throws -> [SyncRepository] {
        let parent = parent ?? root
        var result: [SyncRepository] = []
        for index in 0..<count {
            let working = parent.appendingPathComponent("repo-\(index)")
            let remote = root.appendingPathComponent("remote-\(index).git")
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: working)
            try git(["config", "user.name", "Branchline Test"], at: working)
            try git(["config", "user.email", "branchline@example.test"], at: working)
            try "base".write(to: working.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try git(["add", "file.txt"], at: working)
            try git(["commit", "-m", "base"], at: working)
            try git(["init", "--bare", "--initial-branch=main", remote.path], at: root)
            try git(["remote", "add", "origin", remote.path], at: working)
            try git(["push", "-u", "origin", "main"], at: working)
            result.append(SyncRepository(url: working, remote: remote))
        }
        return result
    }

    func advanceRemote(for repository: SyncRepository) throws {
        let clone = root.appendingPathComponent("clone-\(UUID().uuidString)")
        try git(["clone", repository.remote.path, clone.path], at: root)
        try git(["config", "user.name", "Branchline Test"], at: clone)
        try git(["config", "user.email", "branchline@example.test"], at: clone)
        try "remote update".write(to: clone.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try git(["add", "remote.txt"], at: clone)
        try git(["commit", "-m", "remote update"], at: clone)
        try git(["push", "origin", "main"], at: clone)
    }

    func addLocalCommit(to repository: SyncRepository) throws {
        try "local update".write(to: repository.url.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try git(["add", "local.txt"], at: repository.url)
        try git(["commit", "-m", "local update"], at: repository.url)
    }

    func head(of repository: SyncRepository) throws -> String { try git(["rev-parse", "HEAD"], at: repository.url) }
    func remoteHead(of repository: SyncRepository) throws -> String { try git(["rev-parse", "refs/heads/main"], at: repository.remote) }

    @MainActor
    func makeStore(_ repositories: [SyncRepository], scanRoots: [URL] = []) throws -> (BranchlineStore, UserDefaults, String) {
        let suite = "SelectedSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let models = repositories.map { Repository(path: $0.url.resolvingSymlinksInPath().path) }
        let catalog = RepositoryCatalogStore(defaults: defaults)
        catalog.save(RepositoryCatalog(repositories: models, scanRoots: scanRoots, selectedRepositoryPath: models.first?.path))
        return (BranchlineStore(arguments: [], catalogStore: catalog), defaults, suite)
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SelectedSyncTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)])
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SyncRepository {
    let url: URL
    let remote: URL
    var path: String { url.resolvingSymlinksInPath().path }
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
