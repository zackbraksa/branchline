import Foundation
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    @MainActor
    struct ManualScanTests {
        @Test func manualScanRestoresExcludedImmediateRepositoriesButAutomaticScanDoesNot() async throws {
            let fixture = try ScanFixture()
            defer { fixture.cleanUp() }

            let scanRoot = fixture.root.appendingPathComponent("projects")
            let immediate = scanRoot.appendingPathComponent("immediate")
            let sentinel = scanRoot.appendingPathComponent("sentinel")
            let nested = scanRoot.appendingPathComponent("group/nested")
            let worktreeSource = fixture.root.appendingPathComponent("worktree-source")
            let worktree = scanRoot.appendingPathComponent("worktrees/worktree")
            try fixture.makeRepository(at: immediate)
            try fixture.makeRepository(at: sentinel)
            try fixture.makeRepository(at: nested)
            try fixture.makeRepository(at: worktreeSource, withCommit: true)
            try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fixture.git(["worktree", "add", "--detach", worktree.path], at: worktreeSource)

            let immediatePath = immediate.resolvingSymlinksInPath().path
            let sentinelPath = sentinel.resolvingSymlinksInPath().path
            let nestedPath = nested.resolvingSymlinksInPath().path
            let worktreePath = worktree.resolvingSymlinksInPath().path
            let excluded = [immediatePath, nestedPath, worktreePath]
            let (store, catalog, defaults, suite) = try fixture.makeStore(scanRoots: [scanRoot], excluded: excluded)
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil {
                store.repositories.contains(where: { $0.path == sentinelPath }) && !store.isScanningFolders
            })
            #expect(!store.repositories.contains(where: { $0.path == immediatePath }))
            #expect(Set(catalog.load().excludedRepositoryPaths) == Set(excluded))

            await store.scanFolder(scanRoot)

            #expect(await waitUntil { store.repositories.contains(where: { $0.path == immediatePath }) && store.scanSummary != nil })
            #expect(Set(store.repositories.map(\.path)) == [immediatePath, sentinelPath])
            #expect(Set(store.sidebarGroups.map(\.root.path)) == [immediatePath, sentinelPath])
            #expect(Set(catalog.load().excludedRepositoryPaths) == Set([nestedPath, worktreePath]))
            #expect(store.scanSummary == "2 repos found in projects · 1 added")
        }

        @Test func manualScanExplainsWhenNoImmediateRepositoriesAreFound() async throws {
            let fixture = try ScanFixture()
            defer { fixture.cleanUp() }
            let scanRoot = fixture.root.appendingPathComponent("empty-projects")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            let (store, catalog, defaults, suite) = try fixture.makeStore()
            defer { defaults.removePersistentDomain(forName: suite) }

            await store.scanFolder(scanRoot)

            #expect(store.repositories.isEmpty)
            #expect(store.scanSummary == "No repos found in empty-projects. Only immediate child folders are checked.")
            #expect(catalog.load().scanRoots == [scanRoot])
        }

        @Test func manualScanRequestedDuringStartupScanRunsAfterItFinishes() async throws {
            let fixture = try ScanFixture()
            defer { fixture.cleanUp() }
            let scanRoot = fixture.root.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            let paths = try (0..<16).map { index -> String in
                let path = scanRoot.appendingPathComponent("repo-\(index)")
                try fixture.makeRepository(at: path)
                return path.resolvingSymlinksInPath().path
            }
            let (store, _, defaults, suite) = try fixture.makeStore(scanRoots: [scanRoot], excluded: paths)
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil { store.isScanningFolders })
            await store.scanFolder(scanRoot)

            #expect(await waitUntil {
                !store.isScanningFolders && store.scanSummary != nil && Set(store.repositories.map(\.path)) == Set(paths)
            })
            #expect(store.scanSummary == "16 repos found in projects · 16 added")
        }
    }
}

private struct ScanFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineManualScan-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func makeRepository(at path: URL, withCommit: Bool = false) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: path)
        if withCommit {
            try git(["config", "user.name", "Branchline Test"], at: path)
            try git(["config", "user.email", "branchline@example.test"], at: path)
            try "initial".write(to: path.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try git(["add", "file.txt"], at: path)
            try git(["commit", "-m", "initial"], at: path)
        }
    }

    @MainActor
    func makeStore(
        scanRoots: [URL] = [],
        excluded: [String] = []
    ) throws -> (BranchlineStore, RepositoryCatalogStore, UserDefaults, String) {
        let suite = "ManualScanTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let catalog = RepositoryCatalogStore(defaults: defaults)
        catalog.save(RepositoryCatalog(
            repositories: [],
            scanRoots: scanRoots,
            selectedRepositoryPath: nil,
            excludedRepositoryPaths: excluded
        ))
        return (BranchlineStore(arguments: [], catalogStore: catalog), catalog, defaults, suite)
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
            throw NSError(domain: "ManualScanTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)])
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
