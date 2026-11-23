import Foundation
import Testing
import BranchlineCore
@testable import Branchline

@MainActor
struct RepositorySelectionTests {
    @Test func multipleSelectionRetainsActiveRepositoryAndHandlesDeselection() throws {
        try withStore { store, _, repos in
            #expect(store.selectedRepositoryPaths == [repos[0].path])
            store.selectRepositories([repos[0].path, repos[1].path])
            #expect(store.selectedRepositoryPaths.count == 2)
            #expect(store.selectedRepositoryPath == repos[0].path)
            store.selectRepositories([repos[1].path])
            #expect(store.selectedRepositoryPath == repos[1].path)
            store.selectRepositories([])
            #expect(store.selectedRepositoryPath == nil)
            #expect(store.selectedRepositoryPaths.isEmpty)
        }
    }

    @Test func bulkRemovalPersistsExclusionsAndPreservesRepositoryFiles() throws {
        try withStore { store, catalog, repos in
            store.selectRepositories([repos[0].path, repos[1].path])
            store.removeSelectedRepositories()
            #expect(store.repositories == [repos[2]])
            #expect(store.selectedRepositoryPath == repos[2].path)
            #expect(store.selectedRepositoryPaths == [repos[2].path])
            #expect(catalog.load().repositories == [repos[2]])
            #expect(Set(catalog.load().excludedRepositoryPaths) == [repos[0].path, repos[1].path])
            for repository in repos {
                let contents = try String(contentsOfFile: repository.path + "/keep.txt", encoding: .utf8)
                #expect(contents == "Keep this file")
            }
            store.removeSelectedRepositories()
            #expect(store.repositories.isEmpty)
            #expect(store.selectedRepositoryPath == nil)
            #expect(store.selectedRepositoryPaths.isEmpty)
        }
    }

    @Test func removingUnselectedRepositoryPreservesMultipleSelection() throws {
        try withStore { store, _, repos in
            store.selectRepositories([repos[0].path, repos[1].path])
            store.removeRepository(repos[2])
            #expect(store.selectedRepositoryPaths == [repos[0].path, repos[1].path])
            #expect(store.selectedRepositoryPath == repos[0].path)
        }
    }

    @Test func operationRowsRemainStableWhenRepositoriesAreRemovedFromTheSidebar() throws {
        try withStore { store, _, repos in
            store.selectRepositories(Set(repos.map(\.path)))
            store.perform(.pull)
            let ids = store.operationResults.map(\.id)
            store.removeRepository(repos[0])
            #expect(store.operationResults.map(\.id) == ids)
            #expect(store.operationResults.map(\.name) == repos.map(\.name))
            store.cancelOperation()
        }
    }

    @Test func reorderingPersistsAcrossLaunchesAndPreservesSelection() throws {
        try withStore { store, catalog, repos in
            store.selectRepositories([repos[0].path, repos[1].path])
            store.moveRepositories(fromOffsets: IndexSet([0, 1]), toOffset: 3)
            let expected = [repos[2], repos[0], repos[1]]
            #expect(store.repositories == expected)
            #expect(catalog.load().repositories == expected)
            #expect(store.selectedRepositoryPaths == [repos[0].path, repos[1].path])
            #expect(store.selectedRepositoryPath == repos[0].path)
            let reopened = BranchlineStore(arguments: [], catalogStore: catalog)
            #expect(reopened.repositories == expected)
            #expect(reopened.selectedRepositoryPath == repos[0].path)
        }
    }

    @Test func repositoriesCanMoveUpAndDown() throws {
        try withStore { store, _, repos in
            store.moveRepositories(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            #expect(store.repositories == [repos[2], repos[0], repos[1]])
            store.moveRepositories(fromOffsets: IndexSet(integer: 0), toOffset: 3)
            #expect(store.repositories == repos)
        }
    }

    private func withStore(_ check: (BranchlineStore, RepositoryCatalogStore, [Repository]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineSelection-\(UUID().uuidString)")
        let suite = "BranchlineSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let repos = try (0..<3).map { index in
            let directory = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "Keep this file".write(to: directory.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            return Repository(path: directory.resolvingSymlinksInPath().path)
        }
        let catalog = RepositoryCatalogStore(defaults: defaults)
        catalog.save(RepositoryCatalog(repositories: repos, scanRoots: [], selectedRepositoryPath: repos[0].path))
        let store = BranchlineStore(arguments: [], catalogStore: catalog)
        try check(store, catalog, repos)
    }
}
