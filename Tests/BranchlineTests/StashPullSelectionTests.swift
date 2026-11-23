import Foundation
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    @MainActor
    struct StashPullSelectionTests {
        @Test func selectedStashAndPullKeepsCapturedTargetsAndReportsEachResult() async throws {
            let fixture = try StashPullSelectionFixture()
            defer { fixture.cleanUp() }
            let repositories = try fixture.repositories()
            let upstream = repositories[0]
            let noUpstream = repositories[1]
            let unselected = repositories[2]

            try fixture.advanceRemote(for: upstream)
            try fixture.advanceRemote(for: unselected)
            let upstreamHeadBefore = try fixture.head(of: upstream)
            let noUpstreamHeadBefore = try fixture.head(of: noUpstream)
            let noUpstreamStashesBefore = try fixture.stashes(of: noUpstream)
            let unselectedHeadBefore = try fixture.head(of: unselected)
            let unselectedTrackingBefore = try fixture.trackingHead(of: unselected)

            try fixture.makeLocalChanges(in: upstream)
            try fixture.makeLocalChanges(in: noUpstream)
            try fixture.makeLocalChanges(in: unselected)
            let upstreamStagedBefore = try fixture.git(["diff", "--cached", "--binary"], at: upstream.url)
            let upstreamUnstagedBefore = try fixture.git(["diff", "--binary"], at: upstream.url)
            let noUpstreamStagedBefore = try fixture.git(["diff", "--cached", "--binary"], at: noUpstream.url)
            let noUpstreamUnstagedBefore = try fixture.git(["diff", "--binary"], at: noUpstream.url)
            let unselectedStagedBefore = try fixture.git(["diff", "--cached", "--binary"], at: unselected.url)
            let unselectedUnstagedBefore = try fixture.git(["diff", "--binary"], at: unselected.url)
            let upstreamStashesBefore = try fixture.stashes(of: upstream)
            let unselectedStashesBefore = try fixture.stashes(of: unselected)

            let (store, defaults, suite) = try fixture.makeStore(repositories)
            defer { defaults.removePersistentDomain(forName: suite) }
            let selected = Set([upstream.path, noUpstream.path])
            store.selectRepositories(selected)

            store.perform(.stashAndPull)

            #expect(Set(store.operationProgress.keys) == selected)
            store.selectRepositories([unselected.path])
            #expect(await waitUntil { !store.isOperationRunning })

            #expect(store.selectedRepositoryPaths == [unselected.path])
            #expect(store.operationDescription == "Stash & Pull")
            #expect(store.showsOperationResults)
            #expect(Set(store.operationProgress.keys) == selected)
            #expect(store.operationProgress[upstream.path] == "Done")
            #expect(store.operationProgress[noUpstream.path] == "Failed")
            #expect(store.operationErrors[upstream.path] == nil)
            #expect(store.operationErrors[noUpstream.path]?.localizedCaseInsensitiveContains("upstream") == true)
            #expect(store.operationProgress[unselected.path] == nil)
            #expect(store.operationErrors[unselected.path] == nil)

            #expect(try fixture.head(of: upstream) == fixture.remoteHead(of: upstream))
            #expect(try fixture.head(of: upstream) != upstreamHeadBefore)
            #expect(try fixture.git(["diff", "--cached", "--binary"], at: upstream.url) == upstreamStagedBefore)
            #expect(try fixture.git(["diff", "--binary"], at: upstream.url) == upstreamUnstagedBefore)
            #expect(try fixture.read("staged.txt", in: upstream.url) == "staged local work\n")
            #expect(try fixture.read("shared.txt", in: upstream.url) == "unstaged local work\n")
            #expect(try fixture.read("untracked.txt", in: upstream.url) == "untracked local work\n")
            #expect(fixture.fileExists("remote.txt", in: upstream.url))
            #expect(try fixture.stashes(of: upstream) == upstreamStashesBefore)

            #expect(try fixture.head(of: noUpstream) == noUpstreamHeadBefore)
            #expect(try fixture.git(["diff", "--cached", "--binary"], at: noUpstream.url) == noUpstreamStagedBefore)
            #expect(try fixture.git(["diff", "--binary"], at: noUpstream.url) == noUpstreamUnstagedBefore)
            #expect(try fixture.read("staged.txt", in: noUpstream.url) == "staged local work\n")
            #expect(try fixture.read("shared.txt", in: noUpstream.url) == "unstaged local work\n")
            #expect(try fixture.read("untracked.txt", in: noUpstream.url) == "untracked local work\n")
            #expect(try fixture.stashes(of: noUpstream) == noUpstreamStashesBefore)

            #expect(try fixture.head(of: unselected) == unselectedHeadBefore)
            #expect(try fixture.trackingHead(of: unselected) == unselectedTrackingBefore)
            #expect(try fixture.head(of: unselected) != fixture.remoteHead(of: unselected))
            #expect(try fixture.git(["diff", "--cached", "--binary"], at: unselected.url) == unselectedStagedBefore)
            #expect(try fixture.git(["diff", "--binary"], at: unselected.url) == unselectedUnstagedBefore)
            #expect(try fixture.read("untracked.txt", in: unselected.url) == "untracked local work\n")
            #expect(try fixture.stashes(of: unselected) == unselectedStashesBefore)
        }
    }
}

private struct StashPullSelectionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineStashPullSelection-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func repositories() throws -> [StashPullSelectionRepository] {
        try [makeRepository("upstream"), makeRepository("no-upstream"), makeRepository("unselected")]
    }

    private func makeRepository(_ name: String) throws -> StashPullSelectionRepository {
        let working = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: working)
        try git(["config", "user.name", "Branchline Test"], at: working)
        try git(["config", "user.email", "branchline@example.test"], at: working)
        try write("base\n", to: "shared.txt", in: working)
        try git(["add", "shared.txt"], at: working)
        try git(["commit", "-m", "base"], at: working)

        guard name != "no-upstream" else { return StashPullSelectionRepository(url: working, remote: nil) }

        let remote = root.appendingPathComponent("\(name).git")
        try git(["init", "--bare", "--initial-branch=main", remote.path], at: root)
        try git(["remote", "add", "origin", remote.path], at: working)
        try git(["push", "-u", "origin", "main"], at: working)
        return StashPullSelectionRepository(url: working, remote: remote)
    }

    func advanceRemote(for repository: StashPullSelectionRepository) throws {
        guard let remote = repository.remote else { throw fixtureError("Repository has no remote") }
        let clone = root.appendingPathComponent("peer-\(UUID().uuidString)")
        try git(["clone", "--branch", "main", remote.path, clone.path], at: root)
        try git(["config", "user.name", "Branchline Peer"], at: clone)
        try git(["config", "user.email", "peer@example.test"], at: clone)
        try write("remote addition\n", to: "remote.txt", in: clone)
        try git(["add", "remote.txt"], at: clone)
        try git(["commit", "-m", "remote addition"], at: clone)
        try git(["push", "origin", "main"], at: clone)
    }

    func makeLocalChanges(in repository: StashPullSelectionRepository) throws {
        try write("staged local work\n", to: "staged.txt", in: repository.url)
        try git(["add", "staged.txt"], at: repository.url)
        try write("unstaged local work\n", to: "shared.txt", in: repository.url)
        try write("untracked local work\n", to: "untracked.txt", in: repository.url)
    }

    func head(of repository: StashPullSelectionRepository) throws -> String {
        try git(["rev-parse", "HEAD"], at: repository.url)
    }

    func remoteHead(of repository: StashPullSelectionRepository) throws -> String {
        guard let remote = repository.remote else { throw fixtureError("Repository has no remote") }
        return try git(["rev-parse", "refs/heads/main"], at: remote)
    }

    func trackingHead(of repository: StashPullSelectionRepository) throws -> String {
        try git(["rev-parse", "refs/remotes/origin/main"], at: repository.url)
    }

    func stashes(of repository: StashPullSelectionRepository) throws -> [String] {
        let result = try git(["stash", "list", "--format=%H"], at: repository.url)
        return result.isEmpty ? [] : result.components(separatedBy: "\n")
    }

    func read(_ relativePath: String, in directory: URL) throws -> String {
        String(decoding: try Data(contentsOf: directory.appendingPathComponent(relativePath)), as: UTF8.self)
    }

    func fileExists(_ relativePath: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
    }

    private func write(_ contents: String, to relativePath: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(relativePath))
    }

    @MainActor
    func makeStore(_ repositories: [StashPullSelectionRepository]) throws -> (BranchlineStore, UserDefaults, String) {
        let suite = "StashPullSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let models = repositories.map { Repository(path: $0.path) }
        let catalog = RepositoryCatalogStore(defaults: defaults)
        catalog.save(RepositoryCatalog(repositories: models, scanRoots: [], selectedRepositoryPath: models.first?.path))
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
                domain: "StashPullSelectionTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)]
            )
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "StashPullSelectionTests.Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct StashPullSelectionRepository {
    let url: URL
    let remote: URL?
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
