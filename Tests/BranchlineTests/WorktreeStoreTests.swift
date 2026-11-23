import Foundation
import Testing
import BranchlineCore
@testable import Branchline

extension GitRepositoryTests {
    @MainActor
    struct WorktreeStoreTests {
        @discardableResult private func git(_ args: [String], _ path: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args; process.currentDirectoryURL = path
            let output = Pipe(), error = Pipe()
            process.standardOutput = output; process.standardError = error
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errors = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "Git fixture", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
            }
            return String(decoding: data, as: UTF8.self)
        }

        @Test func linkedWorktreeSelectionAndRemovalStayOutOfCatalog() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineGroup-\(UUID())")
            let child = root.deletingLastPathComponent().appendingPathComponent("BranchlineChild-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: child) }
            try git(["init", "-b", "main"], root)
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "base"], root)
            try git(["worktree", "add", "-b", "child", child.path], root)
            let repository = Repository(path: root.resolvingSymlinksInPath().path)
            let childPath = child.resolvingSymlinksInPath().path
            let suite = "BranchlineWorktreeTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository], scanRoots: [], selectedRepositoryPath: repository.path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            await store.refreshWorktrees(for: repository)
            #expect(store.sidebarGroups.count == 1)
            #expect(store.sidebarGroups[0].worktrees.contains { $0.path == childPath })
            #expect(store.selectableRepositories.contains { $0.path == childPath })
            store.selectRepositories([childPath])
            #expect(store.selectedRepository?.path == childPath)
            #expect(catalog.load().repositories == [repository])
            store.removeRepositories(paths: [childPath])
            await store.refreshWorktrees(for: repository)
            #expect(!store.sidebarGroups[0].worktrees.contains { $0.path == childPath })
            #expect(FileManager.default.fileExists(atPath: childPath))
            #expect(catalog.load().repositories == [repository])
        }
        @Test func refreshFallsBackWhenSelectedWorktreeDisappears() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineMissing-\(UUID())")
            let child = root.deletingLastPathComponent().appendingPathComponent("BranchlineMissingChild-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: child) }
            try git(["init", "-b", "main"], root)
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "base"], root)
            try git(["worktree", "add", "-b", "child", child.path], root)
            let repository = Repository(path: root.resolvingSymlinksInPath().path)
            let childPath = child.resolvingSymlinksInPath().path
            let suite = "BranchlineMissingTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository], scanRoots: [], selectedRepositoryPath: repository.path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            await store.refreshWorktrees(for: repository)
            store.selectRepositories([childPath])
            #expect(store.selectedRepositoryPath == childPath)
            try FileManager.default.removeItem(at: child)
            await store.refreshWorktrees(for: repository)
            #expect(store.selectedRepositoryPath == repository.path)
            #expect(!store.selectedRepositoryPaths.contains(childPath))
        }

        @Test func presentationAvailabilityRefreshesOutsideViewReadsAndRechecksActions() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineAvailability-\(UUID())")
            let child = root.deletingLastPathComponent().appendingPathComponent("BranchlineAvailabilityChild-\(UUID())")
            let moved = root.deletingLastPathComponent().appendingPathComponent("BranchlineAvailabilityMoved-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: child)
                try? FileManager.default.removeItem(at: moved)
            }
            try git(["init", "-b", "main"], root)
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "base"], root)
            try git(["worktree", "add", "-b", "child", child.path], root)
            let repository = Repository(path: root.resolvingSymlinksInPath().path)
            let childRepository = Repository(path: child.resolvingSymlinksInPath().path)
            let suite = "BranchlineAvailabilityTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository], scanRoots: [], selectedRepositoryPath: repository.path, autoFetchEnabled: false))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            await store.refreshWorktrees(for: repository)
            store.selectRepositories([childRepository.path])
            #expect(await waitUntil { store.commits.count == 1 && !store.isLoadingHistory })
            let snapshot = store.selectableRepositories

            try FileManager.default.moveItem(at: child, to: moved)
            for _ in 0..<100 {
                #expect(store.selectableRepositories == snapshot)
                #expect(store.selectedRepository == childRepository)
            }
            await store.refreshStatus(for: childRepository)
            #expect(!store.selectableRepositories.contains(childRepository))
            #expect(store.statusErrors[childRepository.path] != nil)

            try FileManager.default.moveItem(at: moved, to: child)
            await store.refreshStatus(for: childRepository)
            #expect(store.selectableRepositories == snapshot)
            #expect(store.statusErrors[childRepository.path] == nil)

            try FileManager.default.moveItem(at: child, to: moved)
            store.perform(.fetch, paths: [childRepository.path])
            #expect(store.operationRepositories.isEmpty)
            #expect(!store.isOperationRunning)
            #expect(!store.selectableRepositories.contains(childRepository))

            try FileManager.default.moveItem(at: moved, to: child)
            store.selectRepositories([childRepository.path])
            #expect(store.selectedRepository == childRepository)
            try FileManager.default.moveItem(at: child, to: moved)
            store.selectRepositories([childRepository.path])
            #expect(store.selectedRepositoryPaths.isEmpty)
            #expect(store.selectedRepository == nil)
        }

        private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<200 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        @Test func scopeEmptyErrorAndReset() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineScope-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], root)
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "base"], root)
            try git(["branch", "upstream"], root)
            try git(["branch", "--set-upstream-to=upstream", "main"], root)
            let repository = Repository(path: root.resolvingSymlinksInPath().path)
            let suite = "BranchlineScopeTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository], scanRoots: [], selectedRepositoryPath: repository.path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            #expect(await waitUntil { store.commits.count == 1 && !store.isLoadingHistory })
            store.showSyncHistory(.incoming, for: repository)
            #expect(await waitUntil { store.historyScope == .incoming && store.commits.isEmpty && !store.isLoadingHistory })
            #expect(!store.hasMoreHistory && store.selectedCommitID == nil)
            try git(["branch", "--unset-upstream"], root)
            await store.refreshSelectedStatus()
            #expect(store.repositoryErrors[repository.path] != nil)
            #expect(store.commits.isEmpty && !store.hasMoreHistory)
            store.showAllHistory()
            #expect(await waitUntil { store.historyScope == .all && store.commits.count == 1 && !store.isLoadingHistory })
            #expect(store.repositoryErrors[repository.path] == nil)
            store.showSyncHistory(.outgoing, for: repository)
            store.setBranch(nil)
            await store.refreshSelectedStatus()
            #expect(await waitUntil { store.historyScope == .all && store.commits.count == 1 && !store.isLoadingHistory })
        }

        @Test func selectedFetchDeduplicatesSharedGroup() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineFetch-\(UUID())")
            let child = root.deletingLastPathComponent().appendingPathComponent("BranchlineFetchChild-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: child) }
            try git(["init", "-b", "main"], root)
            try git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "base"], root)
            try git(["worktree", "add", "-b", "child", child.path], root)
            let repository = Repository(path: root.resolvingSymlinksInPath().path)
            let childRepository = Repository(path: child.resolvingSymlinksInPath().path)
            let suite = "BranchlineFetchTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let catalog = RepositoryCatalogStore(defaults: defaults)
            catalog.save(RepositoryCatalog(repositories: [repository, childRepository], scanRoots: [], selectedRepositoryPath: repository.path))
            let store = BranchlineStore(arguments: [], catalogStore: catalog)
            await store.refreshWorktrees(for: repository)
            #expect(store.sidebarGroups.count == 1)
            store.selectRepositories([repository.path, childRepository.path])
            store.perform(.fetch)
            #expect(store.operationRepositories.count == 1)
            await store.operationTask?.value
            #expect(store.repositoryStatuses[repository.path] != nil)
            #expect(store.repositoryStatuses[childRepository.path] != nil)
            #expect(catalog.load().repositories == [repository, childRepository])
        }

    }
}
