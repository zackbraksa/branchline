import Foundation
import BranchlineCore

struct RepositoryCatalog: Codable {
    var repositories: [Repository]
    var scanRoots: [URL]
    var selectedRepositoryPath: String?
    var excludedRepositoryPaths: [String]
    var autoFetchEnabled: Bool
    var autoPullEnabled: Bool
    var autoFetchIntervalMinutes: Int
    var manualOperationConcurrency: Int
    var repositoryFetchDates: [String: Date]

    init(
        repositories: [Repository],
        scanRoots: [URL],
        selectedRepositoryPath: String?,
        excludedRepositoryPaths: [String] = [], autoFetchEnabled: Bool = true, autoPullEnabled: Bool = false,
        autoFetchIntervalMinutes: Int = 5, manualOperationConcurrency: Int = 3,
        repositoryFetchDates: [String: Date] = [:]
    ) {
        self.repositories = repositories
        self.scanRoots = scanRoots
        self.selectedRepositoryPath = selectedRepositoryPath
        self.excludedRepositoryPaths = excludedRepositoryPaths
        self.autoFetchEnabled = autoFetchEnabled
        self.autoPullEnabled = autoPullEnabled
        self.autoFetchIntervalMinutes = autoFetchIntervalMinutes
        self.manualOperationConcurrency = manualOperationConcurrency
        self.repositoryFetchDates = repositoryFetchDates
    }

    static let empty = RepositoryCatalog(repositories: [], scanRoots: [], selectedRepositoryPath: nil)

    private enum CodingKeys: String, CodingKey {
        case repositories, scanRoots, selectedRepositoryPath, excludedRepositoryPaths, autoFetchEnabled, autoPullEnabled, autoFetchIntervalMinutes, manualOperationConcurrency, repositoryFetchDates
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try values.decode([Repository].self, forKey: .repositories)
        scanRoots = try values.decode([URL].self, forKey: .scanRoots)
        selectedRepositoryPath = try values.decodeIfPresent(String.self, forKey: .selectedRepositoryPath)
        excludedRepositoryPaths = try values.decodeIfPresent([String].self, forKey: .excludedRepositoryPaths) ?? []
        autoFetchEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoFetchEnabled) ?? true
        autoPullEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoPullEnabled) ?? false
        autoFetchIntervalMinutes = (try? values.decode(Int.self, forKey: .autoFetchIntervalMinutes)) ?? 5
        manualOperationConcurrency = (try? values.decode(Int.self, forKey: .manualOperationConcurrency)) ?? 3
        repositoryFetchDates = try values.decodeIfPresent([String: Date].self, forKey: .repositoryFetchDates) ?? [:]
    }
}

struct RepositoryCatalogStore {
    private let defaults: UserDefaults
    private let key = "branchline.catalog"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> RepositoryCatalog {
        guard let data = defaults.data(forKey: key),
              let catalog = try? JSONDecoder().decode(RepositoryCatalog.self, from: data) else { return .empty }
        return catalog
    }

    func save(_ catalog: RepositoryCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: key)
    }
}
