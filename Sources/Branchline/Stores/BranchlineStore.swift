import Foundation
import Observation
import AppKit
import SwiftUI
import BranchlineCore

struct SidebarRepositoryGroup: Identifiable {
    let root: Repository
    let worktrees: [GitWorktree]
    var id: String { root.path }
}

@MainActor
@Observable
final class BranchlineStore {
    private(set) var repositories: [Repository] = []
    private(set) var sidebarGroups: [SidebarRepositoryGroup] = [] {
        didSet { refreshSelectableRepositories() }
    }
    private(set) var historyScope: HistoryScope = .all
    private(set) var worktreeErrors: [String: String] = [:]
    private(set) var selectableRepositories: [Repository] = []
    private var groupGeneration = 0
    private(set) var scanRoots: [URL] = []
    private(set) var scanningFolderPaths: Set<String> = []
    var isScanningFolders: Bool { !scanningFolderPaths.isEmpty }
    private(set) var scanSummary: String?
    private(set) var selectedRepositoryPaths: Set<String> = []
    var selectedRepositoryPath: String? {
        didSet {
            guard selectedRepositoryPath != oldValue else { return }
            if let path = selectedRepositoryPath {
                if !selectedRepositoryPaths.contains(path) { selectedRepositoryPaths = [path] }
            } else {
                selectedRepositoryPaths = []
            }
            selectionChanged()
        }
    }
    var selectedCommitID: String? {
        didSet { if selectedCommitID != oldValue { loadSelectedCommitFiles() } }
    }
    var branchFilter: String?
    var includeRemotes = true
    var searchText = ""
    private(set) var searchResults: [Commit] = []
    private(set) var repositoryStatuses: [String: RepositoryStatus] = [:]
    private(set) var repositoryErrors: [String: String] = [:]
    private(set) var statusErrors: [String: String] = [:]
    private(set) var commits: [Commit] = []
    private(set) var refs: [GitRef] = []
    private(set) var hasMoreHistory = false
    private(set) var isLoadingHistory = false
    private(set) var isLoadingFiles = false
    private(set) var selectedFiles: [CommitFile] = []
    private(set) var selectedCommitError: String?
    private(set) var operationProgress: [String: String] = [:]
    private(set) var operationErrors: [String: String] = [:]
    private var operationSummaries: [String: String] = [:]
    private var operationOutcomes: [String: SyncOutcome] = [:]
    private enum OperationRequest { case manual([GitOperation]), pushEligible }
    private var lastOperationRequest: OperationRequest?
    private var eligiblePushContext: [Repository] = []
    private(set) var operationRepositories: [Repository] = []
    var operationResults: [OperationResult] {
        operationRepositories.map {
            OperationResult(id: $0.path, name: $0.name,
                            progress: operationProgress[$0.path] ?? "Waiting",
                            error: operationErrors[$0.path],
                            completionSummary: operationSummaries[$0.path], outcome: operationOutcomes[$0.path])
        }
    }
    private(set) var isOperationRunning = false
    private(set) var showsOperationResults = false
    private(set) var operationDescription: String?
    private(set) var operationTask: Task<Void, Never>?
    private var operationRefreshTask: Task<Void, Never>?
    private var operationRefreshGeneration = 0
    var globalError: String?
    static let allowedAutoFetchIntervals = [1, 2, 5, 10, 15, 30, 60]
    static let manualOperationConcurrencyRange = 1...10
    private(set) var autoFetchEnabled: Bool
    private(set) var autoPullEnabled: Bool
    private(set) var autoFetchIntervalMinutes: Int
    private(set) var manualOperationConcurrency: Int
    private(set) var isAutoFetching = false
    private(set) var lastAutoFetchDate: Date?
    private(set) var backgroundFetchErrors: [String: String] = [:]
    private(set) var backgroundSyncMessages: [String: String] = [:]
    private(set) var repositoryFetchDates: [String: Date]
    private var autoFetchTask: Task<Void, Never>?
    private var autoFetchSleepTask: Task<Void, Error>?
    private var autoFetchStarted = false
    private var startupScanTask: Task<Void, Never>?
    private let autoFetchIntervalOverride: Duration?

    private let client = GitClient()
    private let catalogStore: RepositoryCatalogStore
    private var historyLimit = 500
    private var selectionGeneration = 0
    private var historyGeneration = 0
    private var historyRevealGeneration = 0
    private var fileGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var transientPaths: Set<String> = []
    private var pendingLaunchCommitID: String?
    private var excludedRepositoryPaths: Set<String> = []
    private var pendingManualScanRoots: [String: URL] = [:]

    var selectedRepository: Repository? {
        selectableRepositories.first { $0.path == selectedRepositoryPath } ?? repositories.first { $0.path == selectedRepositoryPath }
    }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        catalogStore: RepositoryCatalogStore = RepositoryCatalogStore(),
        autoFetchInterval: Duration? = nil
    ) {
        self.catalogStore = catalogStore
        self.autoFetchIntervalOverride = autoFetchInterval
        let catalog = catalogStore.load()
        autoFetchEnabled = catalog.autoFetchEnabled
        autoPullEnabled = catalog.autoPullEnabled
        autoFetchIntervalMinutes = Self.allowedAutoFetchIntervals.contains(catalog.autoFetchIntervalMinutes) ? catalog.autoFetchIntervalMinutes : 5
        manualOperationConcurrency = Self.manualOperationConcurrencyRange.contains(catalog.manualOperationConcurrency) ? catalog.manualOperationConcurrency : 3
        let stored = catalog.repositories
        repositories = stored
        selectableRepositories = stored
        sidebarGroups = stored.map { SidebarRepositoryGroup(root: $0, worktrees: []) }
        let savedPaths = Set(stored.map(\.path))
        repositoryFetchDates = catalog.repositoryFetchDates.filter { savedPaths.contains($0.key) }
        scanRoots = catalog.scanRoots
        excludedRepositoryPaths = Set(catalog.excludedRepositoryPaths.map(canonicalPath))
        let selection = catalog.selectedRepositoryPath.flatMap { value in stored.contains(where: { $0.path == value }) ? value : nil }
        selectedRepositoryPath = selection ?? stored.first?.path
        selectedRepositoryPaths = Set(selectedRepositoryPath.map { [$0] } ?? [])
        if let index = arguments.firstIndex(of: "--select-commit"), arguments.indices.contains(index + 1) {
            pendingLaunchCommitID = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--repository"), arguments.indices.contains(index + 1) {
            let path = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.path
            Task { await openTransientRepository(path: path) }
        } else if let path = selectedRepositoryPath, let initial = stored.first(where: { $0.path == path }) {
            Task { await loadRepository(initial) }
        }
        startupScanTask = Task {
            await scanSavedRoots()
            await refreshWorktreeGroups()
            startupScanTask = nil
            scheduleAutoFetch()
        }
    }

    var pendingRepository: Repository?
    private(set) var pendingSnapshot: PendingChanges?
    private(set) var pendingError: String?
    private(set) var pendingMessage: String?
    private(set) var isLoadingPending = false
    private(set) var isDiscardingPending = false
    private var pendingGeneration = 0

    func showPendingChanges(for repository: Repository) {
        pendingRepository = repository
        pendingSnapshot = nil
        pendingMessage = nil
        Task { await refreshPendingChanges() }
    }

    func refreshPendingChanges() async {
        guard let repository = pendingRepository, !isDiscardingPending else { return }
        pendingGeneration += 1
        let generation = pendingGeneration
        isLoadingPending = true
        pendingError = nil
        defer { if generation == pendingGeneration { isLoadingPending = false } }
        do {
            let snapshot = try await client.pendingChanges(repository)
            guard pendingRepository == repository, generation == pendingGeneration else { return }
            pendingSnapshot = snapshot
        } catch {
            guard pendingRepository == repository, generation == pendingGeneration else { return }
            pendingSnapshot = nil
            pendingError = error.localizedDescription
        }
    }

    func discardPendingChanges(snapshot: PendingChanges, paths: Set<String>) async {
        guard let repository = pendingRepository, !isOperationRunning, !isDiscardingPending else { return }
        isOperationRunning = true
        isDiscardingPending = true
        pendingError = nil
        pendingMessage = nil
        let backgroundTask = autoFetchTask
        cancelAutoFetch()
        await backgroundTask?.value
        do {
            _ = try await client.discardChanges(repository, snapshot: snapshot, paths: paths)
            pendingMessage = "Changes discarded. A backup of working files and staged changes is in Trash."
        } catch { pendingError = error.localizedDescription }
        await refreshStatus(repository)
        if selectedRepositoryPath == repository.path { await loadHistory(reset: true, repository: repository) }
        isDiscardingPending = false
        isOperationRunning = false
        let error = pendingError
        await refreshPendingChanges()
        if let error { pendingError = error }
        scheduleAutoFetch()
    }

    func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await validateAndAdd(url.path) }
    }

    func addScanRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to scan for Git repositories"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await scanFolder(url) }
    }

    func scanFolder(_ root: URL) async {
        if !scanRoots.contains(where: { canonicalPath($0.path) == canonicalPath(root.path) }) {
            scanRoots.append(root)
            persist()
        }
        scanSummary = nil
        globalError = nil
        await scanRoot(root, restoringRemovedRepositories: true)
    }

    func removeScanRoot(_ root: URL) {
        scanRoots.removeAll { canonicalPath($0.path) == canonicalPath(root.path) }
        persist()
    }

    func removeRepository(_ repository: Repository) {
        removeRepositories(paths: [repository.path])
    }

    func moveRepositoryGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        moveRepositories(fromOffsets: offsets, toOffset: destination)
    }

    func moveRepositories(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var groups = sidebarGroups
        groups.move(fromOffsets: offsets, toOffset: destination)
        let paths = Set(groups.flatMap { group in [group.root.path] + group.worktrees.map(\.path) })
        let ordered = groups.flatMap { group in
            repositories.filter { repository in repository.path == group.root.path || group.worktrees.contains(where: { $0.path == repository.path }) }
        }
        // Keep saved roots in the order of their displayed groups.
        var seen: Set<String> = []
        repositories = ordered.filter { paths.contains($0.path) && seen.insert($0.path).inserted } + repositories.filter { !seen.contains($0.path) }
        sidebarGroups = groups
        persist()
    }

    func selectRepositories(_ paths: Set<String>) {
        refreshSelectableRepositories()
        let choices = selectableRepositories
        selectedRepositoryPaths = paths.intersection(Set(choices.map(\.path)))
        if selectedRepositoryPath.map({ selectedRepositoryPaths.contains($0) }) != true {
            selectedRepositoryPath = choices.first { selectedRepositoryPaths.contains($0.path) }?.path
        }
    }

    func removeSelectedRepositories() { removeRepositories(paths: selectedRepositoryPaths) }

    func removeRepositories(paths: Set<String>) {
        var removedPaths = paths
        for group in sidebarGroups where paths.contains(group.root.path) {
            removedPaths.formUnion(group.worktrees.map(\.path))
        }
        guard !removedPaths.isEmpty else { return }
        groupGeneration += 1
        cancelAutoFetch()
        for path in removedPaths {
            excludedRepositoryPaths.insert(canonicalPath(path))
            repositoryStatuses[path] = nil; repositoryErrors[path] = nil; statusErrors[path] = nil
            backgroundFetchErrors[path] = nil; backgroundSyncMessages[path] = nil; repositoryFetchDates[path] = nil; transientPaths.remove(path)
        }
        repositories.removeAll { removedPaths.contains($0.path) }
        sidebarGroups = sidebarGroups.filter { !removedPaths.contains($0.root.path) }.map {
            SidebarRepositoryGroup(root: $0.root, worktrees: $0.worktrees.filter { !removedPaths.contains($0.path) })
        }
        selectedRepositoryPaths.subtract(removedPaths)
        if let activePath = selectedRepositoryPath, removedPaths.contains(activePath) {
            selectedRepositoryPath = selectableRepositories.first { selectedRepositoryPaths.contains($0.path) }?.path
                ?? selectableRepositories.first?.path
        }
        persist()
    }

    func relocateRepository(_ repository: Repository) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the new location of \(repository.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let moved = try await client.validate(path: url.path)
                guard !repositories.contains(where: { $0.path == moved.path }) else { return }
                guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
                repositories[index] = moved
                repositoryFetchDates[repository.path] = nil
                repositoryStatuses[repository.path] = nil
                repositoryErrors[repository.path] = nil
                selectedRepositoryPath = moved.path
                persist()
                await refreshWorktreeGroups()
                await loadRepository(moved)
            } catch { globalError = readable(error) }
        }
    }

    func refreshWorktrees(for repository: Repository) async {
        await refreshAllStatuses()
    }

    func refreshSelectedStatus() async {
        refreshSelectableRepositories()
        guard let repository = selectedRepository else { return }
        await refreshStatus(repository)
        await loadHistory(reset: true, repository: repository)
    }

    func refreshStatus(for repository: Repository) async {
        await refreshStatus(repository)
    }

    func refreshAllStatuses() async {
        await refreshWorktreeGroups()
        guard !Task.isCancelled else { return }
        let targets = selectableRepositories.filter { FileManager.default.fileExists(atPath: $0.path) }
        for batchStart in stride(from: 0, to: targets.count, by: 3) {
            guard !Task.isCancelled else { return }
            let batch = Array(targets[batchStart..<min(batchStart + 3, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for repository in batch { group.addTask { await self.refreshStatus(repository) } }
                await group.waitForAll()
            }
        }
        if !Task.isCancelled, let repository = selectedRepository { await loadHistory(reset: true, repository: repository) }
    }

    func dismissGlobalError() { globalError = nil }
    func dismissOperationResults() {
        showsOperationResults = false
        operationRefreshTask?.cancel()
    }

    func loadMoreHistory() {
        guard hasMoreHistory, !isLoadingHistory else { return }
        historyLimit += 500
        Task { await loadHistory(reset: true) }
    }

    func setBranch(_ branch: String?) {
        guard branchFilter != branch || historyScope != .all else { return }
        historyRevealGeneration += 1
        historyGeneration += 1
        if historyScope != .all {
            selectionGeneration += 1
            searchTask?.cancel(); searchText = ""; searchResults = []
        }
        branchFilter = branch
        historyScope = .all
        historyLimit = 500
        Task { await loadHistory(reset: true) }
    }

    func showSyncHistory(_ scope: HistoryScope, for repository: Repository) {
        guard scope != .all else { showAllHistory(); return }
        if selectedRepositoryPath != repository.path { selectedRepositoryPath = repository.path }
        historyRevealGeneration += 1
        historyGeneration += 1
        selectionGeneration += 1
        branchFilter = nil
        historyScope = scope
        searchTask?.cancel(); searchText = ""; searchResults = []
        historyLimit = 500
        Task { await loadHistory(reset: true) }
    }

    func showAllHistory() {
        guard historyScope != .all else { return }
        historyRevealGeneration += 1
        historyGeneration += 1
        selectionGeneration += 1
        historyScope = .all
        searchTask?.cancel(); searchText = ""; searchResults = []
        historyLimit = 500
        Task { await loadHistory(reset: true) }
    }

    func toggleRemoteHistory() {
        historyRevealGeneration += 1
        historyGeneration += 1
        includeRemotes.toggle()
        if !includeRemotes, let branchFilter,
           refs.first(where: { $0.fullName == branchFilter })?.kind == .remoteBranch {
            self.branchFilter = nil
        }
        historyLimit = 500
        Task { await loadHistory(reset: true) }
    }

    func searchCommits(_ query: String) {
        searchTask?.cancel()
        let generation = selectionGeneration
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let repository = selectedRepository else {
            searchResults = []
            return
        }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await client.search(repository, query: query, scope: historyScope)
                guard !Task.isCancelled, generation == selectionGeneration else { return }
                searchResults = result
            } catch is CancellationError {
            } catch {
                guard generation == selectionGeneration else { return }
                repositoryErrors[repository.path] = readable(error)
            }
        }
    }

    func revealSearchResult(_ commit: Commit) {
        guard let repository = selectedRepository else { return }
        historyRevealGeneration += 1
        if branchFilter != nil || !includeRemotes { selectionGeneration += 1 }
        let generation = selectionGeneration
        let revealGeneration = historyRevealGeneration
        Task {
            guard generation == selectionGeneration, revealGeneration == historyRevealGeneration else { return }
            branchFilter = nil
            includeRemotes = true
            historyLimit = max(historyLimit, 500)
            await loadHistory(reset: true, repository: repository)
            while generation == selectionGeneration, revealGeneration == historyRevealGeneration,
                  repository.path == selectedRepositoryPath,
                  !commits.contains(where: { $0.id == commit.id }), hasMoreHistory {
                historyLimit += 500
                await loadHistory(reset: true, repository: repository)
            }
            guard generation == selectionGeneration, revealGeneration == historyRevealGeneration,
                  repository.path == selectedRepositoryPath,
                  let match = commits.first(where: { $0.id == commit.id }) else {
                if generation == selectionGeneration, revealGeneration == historyRevealGeneration {
                    globalError = "The matching commit could not be loaded into this repository's history. Refresh the repository and try again."
                }
                return
            }
            selectedCommitID = match.id
            searchTask?.cancel()
            searchText = ""
            searchResults = []
        }
    }

    func perform(_ operation: GitOperation) {
        perform(operation, paths: selectedRepositoryPaths)
    }

    func perform(_ operation: GitOperation, paths: Set<String>) {
        refreshSelectableRepositories()
        startOperation([operation], repositories: selectableRepositories.filter { paths.contains($0.path) })
    }
    func performBatch(_ operation: GitOperation) { startOperation([operation], repositories: repositories) }

    func setAutoFetchEnabled(_ enabled: Bool) {
        guard autoFetchEnabled != enabled else { return }
        autoFetchEnabled = enabled
        persist()
        if enabled { scheduleAutoFetch() } else { cancelAutoFetch() }
    }

    func setAutoPullEnabled(_ enabled: Bool) {
        guard autoPullEnabled != enabled else { return }
        autoPullEnabled = enabled
        persist()
        cancelAutoFetch()
        scheduleAutoFetch()
    }

    func setAutoFetchIntervalMinutes(_ minutes: Int) {
        guard Self.allowedAutoFetchIntervals.contains(minutes), autoFetchIntervalMinutes != minutes else { return }
        autoFetchIntervalMinutes = minutes
        persist()
        autoFetchSleepTask?.cancel()
    }

    func setManualOperationConcurrency(_ count: Int) {
        guard Self.manualOperationConcurrencyRange.contains(count), manualOperationConcurrency != count else { return }
        manualOperationConcurrency = count
        persist()
    }

    func startBackgroundAutoFetch() {
        guard !autoFetchStarted else { return }
        autoFetchStarted = true
        scheduleAutoFetch()
    }

    func stopBackgroundAutoFetch() {
        autoFetchStarted = false
        cancelAutoFetch()
    }

    private func cancelAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchSleepTask?.cancel()
    }

    private func scheduleAutoFetch() {
        guard autoFetchStarted, autoFetchEnabled, !isOperationRunning, operationRefreshTask == nil, autoFetchTask == nil, startupScanTask == nil else { return }
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.autoFetchPass()
                if Task.isCancelled || self == nil { break }
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = self.autoFetchIntervalOverride.map { $0 * self.autoFetchIntervalMinutes / 5 }
                        ?? .seconds(self.autoFetchIntervalMinutes * 60)
                    let sleepTask = Task { try await Task.sleep(for: interval) }
                    self.autoFetchSleepTask = sleepTask
                    do {
                        try await sleepTask.value
                        self.autoFetchSleepTask = nil
                        break
                    } catch {
                        self.autoFetchSleepTask = nil
                    }
                }
            }
            self?.autoFetchTask = nil
            self?.scheduleAutoFetch()
        }
    }

    private func autoFetchPass() async {
        guard autoFetchEnabled, !isOperationRunning, !Task.isCancelled else { return }
        let concurrency = manualOperationConcurrency
        let autoPull = autoPullEnabled
        let targets = repositories.filter { !transientPaths.contains($0.path) }
        isAutoFetching = true
        defer { isAutoFetching = false }
        await refreshWorktreeGroups()
        let batches = await repositoryGroups(targets)
        await withTaskGroup(of: [RepositorySyncResult].self) { group in
            var next = 0
            for _ in 0..<min(concurrency, batches.count) {
                let batch = batches[next]; next += 1
                group.addTask { await self.synchronizeBackground(batch, autoPull: autoPull) }
            }
            while let results = await group.next() {
                guard !Task.isCancelled, autoFetchEnabled else { group.cancelAll(); continue }
                if let fetched = results.first(where: { result in
                    result.fetched && repositories.contains(where: { $0.path == result.repository.path })
                }) { recordSharedFetch(for: fetched.repository) }
                for result in results where repositories.contains(where: { $0.path == result.repository.path }) {
                    backgroundSyncMessages[result.repository.path] = syncSummary(result)
                    backgroundFetchErrors[result.repository.path] = result.outcome == .failed ? result.message ?? "Remote check failed" : nil
                }
                if next < batches.count {
                    let batch = batches[next]; next += 1
                    group.addTask { await self.synchronizeBackground(batch, autoPull: autoPull) }
                }
                await refreshStatusesAfterSync(results.map(\.repository))
            }
        }
        if !Task.isCancelled { lastAutoFetchDate = Date() }
    }

    private func synchronizeBackground(_ targets: [Repository], autoPull: Bool) async -> [RepositorySyncResult] {
        guard !Task.isCancelled, autoFetchEnabled, !isOperationRunning else { return [] }
        let current = targets.filter { repository in
            repositories.contains(where: { $0.path == repository.path }) && !transientPaths.contains(repository.path)
        }
        return await client.synchronize(current, mode: .background(autoPull: autoPull), timeout: 60)
    }

    private func repositoryGroups(_ targets: [Repository]) async -> [[Repository]] {
        var indices: [String: Int] = [:]
        var groups: [[Repository]] = []
        var seen: Set<String> = []
        for repository in targets where seen.insert(repository.path).inserted {
            guard !Task.isCancelled else { return [] }
            let key = (try? await client.commonDirectory(repository)) ?? repository.path
            if let index = indices[key] {
                groups[index].append(repository)
            } else {
                indices[key] = groups.count
                groups.append([repository])
            }
        }
        return groups
    }

    private func refreshStatusesAfterSync(_ targets: [Repository]) async {
        let paths = Set(targets.map(\.path))
        let groups = sidebarGroups.filter { group in
            paths.contains(group.root.path) || group.worktrees.contains(where: { paths.contains($0.path) })
        }
        for group in groups {
            await refreshStatus(group.root)
            for tree in group.worktrees where FileManager.default.fileExists(atPath: tree.path) {
                await refreshStatus(Repository(path: tree.path))
            }
        }
        if let selected = selectedRepository,
           groups.contains(where: { $0.root.path == selected.path || $0.worktrees.contains(where: { $0.path == selected.path }) }) {
            await loadHistory(reset: true, repository: selected)
        }
    }

    private func syncSummary(_ result: RepositorySyncResult) -> String {
        if let message = result.message { return message }
        if let reason = result.reason { return reason.description }
        switch result.outcome {
        case .updated: return "Updated"
        case .upToDate: return "Up to date"
        case .skipped: return "Skipped"
        case .failed: return "Remote check failed"
        case .cancelled: return "Cancelled"
        }
    }

    var canRetryFailedOperation: Bool {
        let available = Set(selectableRepositories.map(\.path))
        return !isOperationRunning && lastOperationRequest != nil && operationResults.contains { $0.isFailure && available.contains($0.id) }
    }

    func retryFailedOperation() {
        refreshSelectableRepositories()
        guard canRetryFailedOperation, let request = lastOperationRequest else { return }
        let failed = Set(operationResults.filter(\.isFailure).map(\.id))
        let targets = selectableRepositories.filter { failed.contains($0.path) }
        switch request {
        case .manual(let operations):
            if operations.contains(.push) {
                startEligiblePush(repositories: targets, context: operationRepositories + repositories.filter { !transientPaths.contains($0.path) })
            } else {
                startOperation(operations, repositories: targets)
            }
        case .pushEligible: startEligiblePush(repositories: targets, context: eligiblePushContext + repositories.filter { !transientPaths.contains($0.path) })
        }
    }

    func performPushAllEligible() {
        startEligiblePush(repositories: repositories.filter { !transientPaths.contains($0.path) })
    }

    private func startEligiblePush(repositories targets: [Repository], context: [Repository]? = nil) {
        guard !isOperationRunning, !targets.isEmpty else { return }
        operationRefreshTask?.cancel()
        isOperationRunning = true
        let backgroundTask = autoFetchTask
        cancelAutoFetch()
        showsOperationResults = true
        lastOperationRequest = .pushEligible
        eligiblePushContext = context ?? targets
        let pushContext = eligiblePushContext
        operationRepositories = targets
        operationErrors = [:]
        operationSummaries = [:]
        operationOutcomes = [:]
        operationProgress = Dictionary(uniqueKeysWithValues: targets.map { ($0.path, "Waiting") })
        operationDescription = "Push All Eligible"
        let concurrency = manualOperationConcurrency
        operationTask = Task {
            await backgroundTask?.value
            let targetPaths = Set(targets.map(\.path))
            let destinations = await client.pushDestinations(pushContext + targets)
            let contextGroups = await repositoryGroups(pushContext + targets)
            let batches = contextGroups.compactMap { context -> ([Repository], [Repository])? in
                let members = context.filter { targetPaths.contains($0.path) }
                return members.isEmpty ? nil : (members, context)
            }
            await withTaskGroup(of: [RepositorySyncResult].self) { group in
                var next = 0
                for _ in 0..<min(concurrency, batches.count) {
                    let batch = batches[next]; next += 1
                    group.addTask { await self.pushEligibleGroup(batch.0, context: batch.1, destinations: destinations) }
                }
                while let results = await group.next() {
                    for result in results {
                        recordSyncResult(result)
                    }
                    if next < batches.count, !Task.isCancelled {
                        let batch = batches[next]; next += 1
                        group.addTask { await self.pushEligibleGroup(batch.0, context: batch.1, destinations: destinations) }
                    }
                }
            }
            for target in targets where operationOutcomes[target.path] == nil {
                operationOutcomes[target.path] = .cancelled
                operationProgress[target.path] = "Cancelled"
            }
            finishOperation()
        }
    }

    private func pushEligibleGroup(_ targets: [Repository], context: [Repository], destinations: [String: String]) async -> [RepositorySyncResult] {
        guard !Task.isCancelled else { return [] }
        for target in targets { operationProgress[target.path] = "Checking remote" }
        return await client.synchronize(targets, mode: .pushEligible, timeout: 120, pushContext: context, pushDestinations: destinations)
    }

    private func recordSyncResult(_ result: RepositorySyncResult) {
        let path = result.repository.path
        operationOutcomes[path] = result.outcome
        operationSummaries[path] = syncSummary(result)
        operationErrors[path] = result.outcome == .failed ? result.message ?? "Remote check failed" : nil
        switch result.outcome {
        case .updated, .upToDate: operationProgress[path] = "Done"
        case .skipped: operationProgress[path] = "Skipped"
        case .failed: operationProgress[path] = "Failed"
        case .cancelled: operationProgress[path] = "Cancelled"
        }
        if result.fetched, selectableRepositories.contains(where: { $0.path == path }) {
            recordSharedFetch(for: result.repository)
        }
    }

    func cancelOperation() { operationTask?.cancel() }

    private func finishOperation() {
        isOperationRunning = false
        operationTask = nil
        if case .manual(let operations) = lastOperationRequest,
           operations == [.pull] || operations == [.stashAndPull],
           operationResults.allSatisfy({ $0.progress == "Done" && $0.error == nil }) {
            showsOperationResults = false
        }
        operationRefreshGeneration += 1
        let generation = operationRefreshGeneration
        operationRefreshTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.refreshAllStatuses() }
                group.addTask { try? await Task.sleep(for: .seconds(30)) }
                await group.next()
                group.cancelAll()
            }
            guard generation == operationRefreshGeneration else { return }
            operationRefreshTask = nil
            scheduleAutoFetch()
        }
    }

    private func startOperation(_ operations: [GitOperation], repositories requestedTargets: [Repository]) {
        var seenGroups: Set<String> = []
        let targets = requestedTargets.filter { repository in
            guard operations == [.fetch] else { return true }
            let group = sidebarGroups.first { $0.root.path == repository.path || $0.worktrees.contains(where: { $0.path == repository.path }) }
            return seenGroups.insert(group?.root.path ?? repository.path).inserted
        }
        guard !isOperationRunning, !targets.isEmpty else { return }
        operationRefreshTask?.cancel()
        isOperationRunning = true
        let backgroundTask = autoFetchTask
        cancelAutoFetch()
        showsOperationResults = true
        lastOperationRequest = .manual(operations)
        operationRepositories = targets
        operationErrors = [:]
        operationSummaries = [:]
        operationOutcomes = [:]
        operationProgress = Dictionary(uniqueKeysWithValues: targets.map { ($0.path, "Waiting") })
        operationDescription = operations.map(\.title).joined(separator: " → ")
        let concurrency = manualOperationConcurrency
        operationTask = Task {
            await backgroundTask?.value
            let batches = await repositoryGroups(targets)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(concurrency, batches.count) {
                    let batch = batches[next]; next += 1
                    group.addTask { await self.runManualGroup(operations, repositories: batch) }
                }
                while await group.next() != nil {
                    if next < batches.count, !Task.isCancelled {
                        let batch = batches[next]; next += 1
                        group.addTask { await self.runManualGroup(operations, repositories: batch) }
                    }
                }
            }
            for target in targets where operationOutcomes[target.path] == nil {
                operationOutcomes[target.path] = .cancelled
                operationProgress[target.path] = "Cancelled"
            }
            finishOperation()
        }
    }

    private func runManualGroup(_ operations: [GitOperation], repositories targets: [Repository]) async {
        var sharedFetchResult: String?
        for (index, repository) in targets.enumerated() {
            guard !Task.isCancelled else { return }
            let error: String?
            if operations == [.fetch], index > 0 {
                error = sharedFetchResult
                if error == nil { await recordOperationCompletion(.fetch, for: repository) }
            } else {
                let result = await run(operations, on: repository)
                error = result.1
                sharedFetchResult = error
            }
            if error == "Cancelled" {
                operationOutcomes[repository.path] = .cancelled
                operationProgress[repository.path] = "Cancelled"
            } else if let error {
                operationErrors[repository.path] = error
                operationOutcomes[repository.path] = .failed
                operationProgress[repository.path] = "Failed"
            } else {
                operationOutcomes[repository.path] = .updated
                operationProgress[repository.path] = "Done"
            }
        }
    }

    private func run(_ operations: [GitOperation], on repository: Repository) async -> (String, String?) {
        for operation in operations {
            if Task.isCancelled { return (repository.path, "Cancelled") }
            operationProgress[repository.path] = operation.title
            do {
                try await client.perform(operation, on: repository, onProgress: { phase in
                    await self.updateOperationProgress(phase, for: repository)
                })
                try Task.checkCancellation()
                if !Task.isCancelled, [.fetch, .pull, .stashAndPull].contains(operation),
                   selectableRepositories.contains(where: { $0.path == repository.path }) {
                    recordSharedFetch(for: repository)
                }
                operationProgress[repository.path] = "Refreshing status"
                await recordOperationCompletion(operation, for: repository)
                try Task.checkCancellation()
            }
            catch is CancellationError { return (repository.path, "Cancelled") }
            catch { return (repository.path, readable(error)) }
        }
        return (repository.path, nil)
    }

    private func recordSharedFetch(for repository: Repository) {
        let group = sidebarGroups.first {
            $0.root.path == repository.path || $0.worktrees.contains(where: { $0.path == repository.path })
        }
        let paths = group.map { [$0.root.path] + $0.worktrees.map(\.path) } ?? [repository.path]
        let date = Date()
        for path in paths where FileManager.default.fileExists(atPath: path) {
            repositoryFetchDates[path] = date
            backgroundFetchErrors[path] = nil
        }
        persist()
    }

    private func updateOperationProgress(_ phase: GitOperationPhase, for repository: Repository) {
        operationProgress[repository.path] = phase.rawValue
    }

    private func recordOperationCompletion(_ operation: GitOperation, for repository: Repository) async {
        var status: RepositoryStatus?
        do {
            let fresh = try await client.status(repository)
            guard !Task.isCancelled else { return }
            repositoryStatuses[repository.path] = fresh
            statusErrors[repository.path] = nil
            status = fresh
        } catch {
            guard !Task.isCancelled else { return }
            statusErrors[repository.path] = readable(error)
        }
        operationSummaries[repository.path] = OperationResult.summary(for: operation, status: status)
    }

    private func selectionChanged() {
        selectionGeneration += 1
        historyRevealGeneration += 1
        historyGeneration += 1
        fileGeneration += 1
        historyLimit = 500
        branchFilter = nil
        historyScope = .all
        includeRemotes = true
        selectedCommitID = nil
        commits = []; refs = []; selectedFiles = []; searchResults = []
        searchTask?.cancel()
        searchText = ""
        isLoadingFiles = false
        isLoadingHistory = false
        hasMoreHistory = false
        selectedCommitError = nil
        persist()
        guard let repository = selectedRepository else { return }
        Task { await loadRepository(repository) }
    }

    private func loadRepository(_ repository: Repository) async {
        refreshSelectableRepositories()
        guard FileManager.default.fileExists(atPath: repository.path) else {
            statusErrors[repository.path] = "This worktree is unavailable."
            return
        }
        async let status: Void = refreshStatus(repository)
        async let history: Void = loadHistory(reset: true, repository: repository)
        _ = await (status, history)
    }

    private func refreshStatus(_ repository: Repository) async {
        refreshSelectableRepositories()
        guard FileManager.default.fileExists(atPath: repository.path) else {
            statusErrors[repository.path] = "This worktree is unavailable."
            return
        }
        do {
            let status = try await client.status(repository)
            guard !Task.isCancelled else { return }
            refreshSelectableRepositories()
            guard selectableRepositories.contains(where: { $0.path == repository.path }) || repositories.contains(where: { $0.path == repository.path }) else { return }
            repositoryStatuses[repository.path] = status
            statusErrors[repository.path] = nil
        } catch {
            guard !Task.isCancelled else { return }
            refreshSelectableRepositories()
            guard selectableRepositories.contains(where: { $0.path == repository.path }) || repositories.contains(where: { $0.path == repository.path }) else { return }
            statusErrors[repository.path] = readable(error)
        }
    }

    private func loadHistory(reset: Bool, repository explicitRepository: Repository? = nil) async {
        guard let repository = explicitRepository ?? selectedRepository,
              repository.path == selectedRepositoryPath,
              FileManager.default.fileExists(atPath: repository.path) else { return }
        historyGeneration += 1
        let generation = historyGeneration
        isLoadingHistory = true
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        do {
            let page = try await client.history(repository, limit: historyLimit, branch: branchFilter, includeRemotes: includeRemotes, scope: historyScope)
            guard !Task.isCancelled, generation == historyGeneration, repository.path == selectedRepositoryPath else { return }
            commits = page.commits
            refs = page.refs
            hasMoreHistory = page.hasMore
            if let pendingLaunchCommitID,
               let launchCommit = commits.first(where: { $0.id.hasPrefix(pendingLaunchCommitID) }) {
                selectedCommitID = launchCommit.id
                self.pendingLaunchCommitID = nil
            }
            if selectedCommitID == nil || !commits.contains(where: { $0.id == selectedCommitID }) { selectedCommitID = commits.first?.id }
            repositoryErrors[repository.path] = nil
        } catch {
            guard !Task.isCancelled, generation == historyGeneration else { return }
            repositoryErrors[repository.path] = readable(error)
            if reset { commits = []; refs = []; hasMoreHistory = false; selectedCommitID = nil }
        }
    }

    private func loadSelectedCommitFiles() {
        fileGeneration += 1
        let generation = fileGeneration
        guard let repository = selectedRepository, let commit = commits.first(where: { $0.id == selectedCommitID }) else {
            selectedFiles = []; selectedCommitError = nil; isLoadingFiles = false; return
        }
        isLoadingFiles = true
        Task {
            defer { if generation == fileGeneration { isLoadingFiles = false } }
            do {
                let files = try await client.files(repository, commit: commit)
                guard generation == fileGeneration, repository.path == selectedRepositoryPath, commit.id == selectedCommitID else { return }
                selectedFiles = files
                selectedCommitError = nil
            } catch {
                guard generation == fileGeneration else { return }
                selectedFiles = []
                selectedCommitError = readable(error)
            }
        }
    }

    private func validateAndAdd(_ path: String) async {
        do {
            let repository = try await client.validate(path: path)
            excludedRepositoryPaths.remove(canonicalPath(repository.path))
            if !repositories.contains(where: { $0.id == repository.id }) { repositories.append(repository) }
            transientPaths.remove(repository.path)
            selectedRepositoryPath = repository.path
            persist()
            await refreshWorktreeGroups()
        } catch { globalError = readable(error) }
    }

    private func openTransientRepository(path: String) async {
        do {
            let repository = try await client.validate(path: path)
            if !repositories.contains(where: { $0.id == repository.id }) {
                repositories.append(repository)
                transientPaths.insert(repository.path)
            }
            await refreshWorktreeGroups()
            selectedRepositoryPath = repository.path
        } catch { globalError = readable(error) }
    }

    private func scanSavedRoots() async { for root in scanRoots { await scanRoot(root) } }

    private func scanRoot(_ root: URL, restoringRemovedRepositories: Bool = false) async {
        let path = canonicalPath(root.path)
        guard scanningFolderPaths.insert(path).inserted else {
            if restoringRemovedRepositories { pendingManualScanRoots[path] = root }
            return
        }
        defer {
            scanningFolderPaths.remove(path)
            if let pending = pendingManualScanRoots.removeValue(forKey: path) {
                Task { await self.scanRoot(pending, restoringRemovedRepositories: true) }
            }
        }
        do {
            let found = try await RepositoryDiscovery.scan(root)
            guard scanRoots.contains(where: { canonicalPath($0.path) == path }) else { return }
            if restoringRemovedRepositories {
                excludedRepositoryPaths.subtract(found.map { canonicalPath($0.path) })
            }
            var added = 0
            for repository in found where !excludedRepositoryPaths.contains(canonicalPath(repository.path)) && !transientPaths.contains(repository.path) {
                if !repositories.contains(where: { $0.id == repository.id }) {
                    repositories.append(repository)
                    added += 1
                }
            }
            if restoringRemovedRepositories, selectedRepositoryPath == nil {
                selectedRepositoryPath = repositories.first?.path
            }
            persist()
            await refreshWorktreeGroups()
            let foundPaths = Set(found.map(\.path))
            let discoveredPaths = Set(sidebarGroups.filter { group in
                foundPaths.contains(group.root.path) || group.worktrees.contains(where: { foundPaths.contains($0.path) })
            }.flatMap { group in [group.root.path] + group.worktrees.map(\.path) })
            for repository in selectableRepositories where discoveredPaths.contains(repository.path) {
                await refreshStatus(repository)
            }
            if restoringRemovedRepositories {
                if found.isEmpty {
                    scanSummary = "No repos found in \(root.lastPathComponent). Only immediate child folders are checked."
                } else {
                    let noun = found.count == 1 ? "repo" : "repos"
                    scanSummary = "\(found.count) \(noun) found in \(root.lastPathComponent) · \(added) added"
                }
            }
        } catch { globalError = readable(error) }
    }

    private func refreshSelectableRepositories() {
        let available = sidebarGroups.flatMap { group in
            [group.root] + group.worktrees.filter {
                !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path)
            }.map { Repository(path: $0.path) }
        }
        if selectableRepositories != available { selectableRepositories = available }
    }

    private func refreshWorktreeGroups() async {
        groupGeneration += 1
        let generation = groupGeneration
        let roots = repositories
        var groups: [SidebarRepositoryGroup] = []
        var errors: [String: String] = [:]
        var seenCommon: Set<String> = []
        for root in roots {
            guard !Task.isCancelled, generation == groupGeneration else { return }
            do {
                let common = try await client.commonDirectory(root)
                guard !seenCommon.contains(common) else { continue }
                let trees = try await client.worktrees(root).filter {
                    !$0.isBare && $0.path != root.path && !excludedRepositoryPaths.contains(canonicalPath($0.path))
                }
                seenCommon.insert(common)
                groups.append(SidebarRepositoryGroup(root: root, worktrees: trees))
            } catch {
                errors[root.path] = readable(error)
                groups.append(SidebarRepositoryGroup(root: root, worktrees: []))
            }
        }
        guard !Task.isCancelled, generation == groupGeneration, roots == repositories else { return }
        let previousActive = selectedRepositoryPath
        let previousRoot = sidebarGroups.first {
            $0.root.path == previousActive || $0.worktrees.contains(where: { $0.path == previousActive })
        }?.root.path
        worktreeErrors = errors
        sidebarGroups = groups
        let available = Set(selectableRepositories.map(\.path))
        selectedRepositoryPaths.formIntersection(available)
        if let previousActive, !available.contains(previousActive) {
            selectedRepositoryPath = previousRoot.flatMap { available.contains($0) ? $0 : nil }
                ?? selectableRepositories.first { selectedRepositoryPaths.contains($0.path) }?.path
                ?? selectableRepositories.first?.path
        }
        let rootPaths = Set(groups.map(\.root.path))
        for repository in selectableRepositories where !rootPaths.contains(repository.path) && repositoryStatuses[repository.path] == nil {
            guard generation == groupGeneration else { return }
            await refreshStatus(repository)
        }
    }

    private func persist() {
        let savedRepositories = repositories.filter { !transientPaths.contains($0.path) }
        let savedPaths = Set(savedRepositories.map(\.path))
        catalogStore.save(RepositoryCatalog(
            repositories: savedRepositories,
            scanRoots: scanRoots,
            selectedRepositoryPath: selectedRepositoryPath.flatMap { savedPaths.contains($0) ? $0 : nil },
            excludedRepositoryPaths: excludedRepositoryPaths.sorted(),
            autoFetchEnabled: autoFetchEnabled,
            autoPullEnabled: autoPullEnabled,
            autoFetchIntervalMinutes: autoFetchIntervalMinutes,
            manualOperationConcurrency: manualOperationConcurrency,
            repositoryFetchDates: repositoryFetchDates.filter { savedPaths.contains($0.key) }
        ))
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func readable(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "The Git operation failed. Check that this folder is accessible and Git is installed." }
        // Do not let remote URLs with embedded credentials reach the UI.
        return message.replacingOccurrences(of: #"(https?://)[^/@\s]+:[^/@\s]+@"#, with: "$1[credentials]@", options: .regularExpression)
    }
}
