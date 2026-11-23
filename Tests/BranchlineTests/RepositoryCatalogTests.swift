import Foundation
import Testing
import BranchlineCore
@testable import Branchline

struct RepositoryCatalogTests {
    @Test func remembersRepositoriesRootsAndSelection() throws {
        let suite = "BranchlineCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RepositoryCatalogStore(defaults: defaults)
        let repo = Repository(path: "/tmp/Projects/雪 repo")
        store.save(RepositoryCatalog(repositories: [repo], scanRoots: [URL(fileURLWithPath: "/tmp/Projects")], selectedRepositoryPath: repo.path, excludedRepositoryPaths: ["/tmp/Projects/hidden"]))
        let loaded = store.load()
        #expect(loaded.repositories == [repo])
        #expect(loaded.scanRoots.map(\.path) == ["/tmp/Projects"])
        #expect(loaded.selectedRepositoryPath == repo.path)
        #expect(loaded.excludedRepositoryPaths == ["/tmp/Projects/hidden"])
    }

    @Test func missingOrUnreadableCatalogStartsEmpty() throws {
        let suite = "BranchlineCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RepositoryCatalogStore(defaults: defaults)
        #expect(store.load().repositories.isEmpty)
        defaults.set(Data("invalid".utf8), forKey: "branchline.catalog")
        #expect(store.load().repositories.isEmpty)
    }

    @Test func olderCatalogDefaultsToNoExclusions() throws {
        let data = Data(#"{"repositories":[],"scanRoots":[]}"#.utf8)
        let loaded = try JSONDecoder().decode(RepositoryCatalog.self, from: data)
        #expect(loaded.excludedRepositoryPaths.isEmpty)
        #expect(loaded.selectedRepositoryPath == nil)
        #expect(loaded.autoFetchEnabled)
        #expect(!loaded.autoPullEnabled)
        #expect(loaded.autoFetchIntervalMinutes == 5)
        #expect(loaded.manualOperationConcurrency == 3)
        #expect(loaded.repositoryFetchDates.isEmpty)
    }

    @Test func fetchDatesRoundTrip() throws {
        let suite = "BranchlineCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RepositoryCatalogStore(defaults: defaults)
        let repo = Repository(path: "/tmp/repo")
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(RepositoryCatalog(repositories: [repo], scanRoots: [], selectedRepositoryPath: repo.path, repositoryFetchDates: [repo.path: fetchedAt]))
        #expect(store.load().repositoryFetchDates[repo.path] == fetchedAt)
    }
    @MainActor
    @Test func settingsPersistAndInvalidValuesFallBack() throws {
        let suite = "BranchlineCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = RepositoryCatalogStore(defaults: defaults)
        let store = BranchlineStore(arguments: [], catalogStore: catalog)
        store.setAutoFetchIntervalMinutes(15)
        store.setManualOperationConcurrency(7)
        let restored = BranchlineStore(arguments: [], catalogStore: catalog)
        #expect(restored.autoFetchIntervalMinutes == 15)
        #expect(restored.manualOperationConcurrency == 7)
        restored.setAutoFetchIntervalMinutes(3)
        restored.setManualOperationConcurrency(11)
        #expect(restored.autoFetchIntervalMinutes == 15)
        #expect(restored.manualOperationConcurrency == 7)

        defaults.set(Data(#"{"repositories":[],"scanRoots":[],"autoFetchIntervalMinutes":99,"manualOperationConcurrency":0}"#.utf8), forKey: "branchline.catalog")
        let invalid = BranchlineStore(arguments: [], catalogStore: catalog)
        #expect(invalid.autoFetchIntervalMinutes == 5)
        #expect(invalid.manualOperationConcurrency == 3)
        defaults.set(Data(#"{"repositories":[],"scanRoots":[],"autoFetchIntervalMinutes":"bad","manualOperationConcurrency":null}"#.utf8), forKey: "branchline.catalog")
        let malformed = BranchlineStore(arguments: [], catalogStore: catalog)
        #expect(malformed.autoFetchIntervalMinutes == 5)
        #expect(malformed.manualOperationConcurrency == 3)
    }

}
