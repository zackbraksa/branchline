import Foundation
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    @MainActor
    struct BranchlineStoreTests {
        @Test func loadMoreHistoryRaisesInitial500CommitPageTo1000() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repositoryPath = root.appendingPathComponent("history")
            try makeHistoryRepository(at: repositoryPath, commitCount: 1_100)
            let (store, defaults, suite) = try makeStore(repositoryPaths: [repositoryPath])
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil { store.commits.count == 500 && !store.isLoadingHistory })
            #expect(store.hasMoreHistory)

            store.loadMoreHistory()

            #expect(await waitUntil { store.commits.count == 1_000 && !store.isLoadingHistory })
            #expect(store.hasMoreHistory)
        }

        @Test func revealingOlderSearchResultLoadsItIntoHistoryAndClearsSearch() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repositoryPath = root.appendingPathComponent("search")
            try makeHistoryRepository(at: repositoryPath, commitCount: 1_100)
            let (store, defaults, suite) = try makeStore(repositoryPaths: [repositoryPath])
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil { store.commits.count == 500 && !store.isLoadingHistory })
            store.searchText = "older-target"
            store.searchCommits(store.searchText)
            #expect(await waitUntil { store.searchResults.contains(where: { $0.subject == "older-target" }) })
            let target = try #require(store.searchResults.first(where: { $0.subject == "older-target" }))
            #expect(!store.commits.contains(where: { $0.id == target.id }))

            store.revealSearchResult(target)

            #expect(await waitUntil {
                store.selectedCommitID == target.id && store.commits.contains(where: { $0.id == target.id })
            })
            #expect(store.searchText.isEmpty)
            #expect(store.commits.count == 1_100)
            #expect(store.commits.contains(where: { $0.id == target.id }))
        }

        @Test func rapidRepositorySwitchDoesNotLeaveOldCommitFilesSelected() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let slowPath = root.appendingPathComponent("large-files")
            let nextPath = root.appendingPathComponent("next")
            try makeFileRepository(at: slowPath, fileCount: 5_000, prefix: "old")
            try makeFileRepository(at: nextPath, fileCount: 1, prefix: "new")
            let (store, defaults, suite) = try makeStore(repositoryPaths: [slowPath, nextPath], selectedPath: slowPath.path)
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil {
                store.selectedRepositoryPath == slowPath.path &&
                store.commits.count == 1 && !store.isLoadingHistory && !store.isLoadingFiles
            })
            let oldCommit = try #require(store.commits.first)

            store.selectedCommitID = nil
            store.selectedCommitID = oldCommit.id
            store.selectedRepositoryPath = nextPath.path

            #expect(await waitUntil {
                store.selectedRepositoryPath == nextPath.path &&
                store.commits.count == 1 && !store.isLoadingHistory && !store.isLoadingFiles &&
                store.selectedFiles.count == 1 && store.selectedFiles.first?.path == "new-00001.txt"
            })
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.selectedFiles.map(\.path) == ["new-00001.txt"])
        }

        @Test func removedRepositoryStaysExcludedWhenSavedScanRootIsRescannedAfterRestart() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let scanRoot = root.appendingPathComponent("projects")
            let removedPath = scanRoot.appendingPathComponent("removed")
            try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
            try makeFileRepository(at: removedPath, fileCount: 1, prefix: "removed")

            let suite = "BranchlineStoreTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalogStore = RepositoryCatalogStore(defaults: defaults)
            let removedRepository = Repository(path: removedPath.resolvingSymlinksInPath().path)
            catalogStore.save(RepositoryCatalog(
                repositories: [removedRepository],
                scanRoots: [scanRoot],
                selectedRepositoryPath: removedRepository.path
            ))

            let firstStore = BranchlineStore(arguments: [], catalogStore: catalogStore)
            #expect(await waitUntil { firstStore.commits.count == 1 && !firstStore.isLoadingHistory })
            firstStore.removeRepository(try #require(firstStore.repositories.first))
            #expect(catalogStore.load().excludedRepositoryPaths.contains(removedRepository.path))

            // This repository appears only after removal, so its rediscovery proves the
            // restarted store completed the saved-root scan before checking exclusions.
            let sentinelPath = scanRoot.appendingPathComponent("sentinel")
            try makeFileRepository(at: sentinelPath, fileCount: 1, prefix: "sentinel")
            let restartedStore = BranchlineStore(arguments: [], catalogStore: catalogStore)

            #expect(await waitUntil {
                restartedStore.repositories.contains(where: { $0.path == sentinelPath.resolvingSymlinksInPath().path })
            })
            #expect(!restartedStore.repositories.contains(where: { $0.path == removedRepository.path }))
            #expect(catalogStore.load().excludedRepositoryPaths.contains(removedRepository.path))
        }

        @Test func batchPullKeepsSuccessAndFailureForEachRepository() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let upstreamPath = root.appendingPathComponent("with-upstream")
            let noUpstreamPath = root.appendingPathComponent("without-upstream")
            try makeFileRepository(at: upstreamPath, fileCount: 1, prefix: "with", checkout: true)
            try makeFileRepository(at: noUpstreamPath, fileCount: 1, prefix: "without", checkout: true)
            try git(["config", "branch.main.remote", "."], at: upstreamPath)
            try git(["config", "branch.main.merge", "refs/heads/main"], at: upstreamPath)
            let (store, defaults, suite) = try makeStore(repositoryPaths: [upstreamPath, noUpstreamPath])
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil { store.commits.count == 1 && !store.isLoadingHistory })
            store.performBatch(.pull)

            #expect(await waitUntil { !store.isOperationRunning })
            #expect(store.operationProgress[upstreamPath.resolvingSymlinksInPath().path] == "Done")
            #expect(store.operationErrors[upstreamPath.resolvingSymlinksInPath().path] == nil)
            #expect(store.operationProgress[noUpstreamPath.resolvingSymlinksInPath().path] == "Failed")
            #expect(store.operationErrors[noUpstreamPath.resolvingSymlinksInPath().path] != nil)
        }

        @Test func refreshAllStatusesCanFinishWhileARepositoryIsRemoved() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = (0..<4).map { root.appendingPathComponent("repo-\($0)") }
            for (index, path) in paths.enumerated() {
                try makeFileRepository(at: path, fileCount: 1_000, prefix: "repo-\(index)")
            }
            let (store, defaults, suite) = try makeStore(repositoryPaths: paths)
            defer { defaults.removePersistentDomain(forName: suite) }

            #expect(await waitUntil { store.commits.count == 1 && !store.isLoadingHistory })
            let removedRepository = try #require(store.repositories.first)
            let refresh = Task { await store.refreshAllStatuses() }
            await Task.yield()
            store.removeRepository(removedRepository)
            await refresh.value

            #expect(!store.repositories.contains(where: { $0.path == removedRepository.path }))
            #expect(store.repositories.allSatisfy { store.repositoryStatuses[$0.path] != nil })
        }

        private func makeStore(repositoryPaths: [URL], selectedPath: String? = nil) throws -> (BranchlineStore, UserDefaults, String) {
            let suite = "BranchlineStoreTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let repositories = repositoryPaths.map { Repository(path: $0.resolvingSymlinksInPath().path) }
            RepositoryCatalogStore(defaults: defaults).save(RepositoryCatalog(
                repositories: repositories,
                scanRoots: [],
                selectedRepositoryPath: selectedPath ?? repositories.first?.path
            ))
            return (BranchlineStore(arguments: [], catalogStore: RepositoryCatalogStore(defaults: defaults)), defaults, suite)
        }

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineStoreTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func makeHistoryRepository(at path: URL, commitCount: Int) throws {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: path)
            var stream = "blob\nmark :1\ndata 1\nx\n"
            for index in 0..<commitCount {
                let subject = index == 0 ? "older-target" : "history-\(index)"
                let commitMark = index + 2
                let timestamp = index + 1
                stream += "commit refs/heads/main\nmark :\(commitMark)\nauthor Branchline Test <branchline@example.test> \(timestamp) +0000\ncommitter Branchline Test <branchline@example.test> \(timestamp) +0000\ndata \(subject.utf8.count)\n\(subject)\n"
                if index > 0 { stream += "from :\(commitMark - 1)\n" }
                stream += "M 100644 :1 history.txt\n"
            }
            try git(["fast-import"], at: path, input: Data(stream.utf8))
        }

        private func makeFileRepository(at path: URL, fileCount: Int, prefix: String, checkout: Bool = false) throws {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: path)
            var stream = "blob\nmark :1\ndata 1\nx\ncommit refs/heads/main\nmark :2\nauthor Branchline Test <branchline@example.test> 1 +0000\ncommitter Branchline Test <branchline@example.test> 1 +0000\ndata 9\nfile root\n"
            for index in 1...fileCount {
                stream += "M 100644 :1 \(prefix)-\(String(format: "%05d", index)).txt\n"
            }
            try git(["fast-import"], at: path, input: Data(stream.utf8))
            if checkout { try git(["reset", "--hard", "HEAD"], at: path) }
        }

        @discardableResult
        private func git(_ arguments: [String], at directory: URL, input: Data? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let output = Pipe(), error = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try? stdin.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "BranchlineStoreTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: err, as: UTF8.self)])
            }
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func waitUntil(
            timeout: Duration = .seconds(20),
            condition: @MainActor () -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
    }
}
