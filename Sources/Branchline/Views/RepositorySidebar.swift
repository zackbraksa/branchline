import SwiftUI
import BranchlineCore

struct RepositorySidebar: View {
    let store: BranchlineStore

    var body: some View {
        List(selection: Binding(get: { store.selectedRepositoryPaths }, set: { store.selectRepositories($0) })) {
            Section("Repositories") {
                ForEach(store.sidebarGroups) { group in
                    if group.worktrees.isEmpty {
                        checkoutRow(group.root)
                    } else {
                        DisclosureGroup {
                            ForEach(group.worktrees) { worktree in
                                let repository = Repository(path: worktree.path)
                                let available = store.selectableRepositories.contains { $0.path == worktree.path }
                                checkoutRow(repository, worktree: worktree)
                                    .selectionDisabled(!available)
                            }
                        } label: {
                            checkoutRow(group.root)
                        }
                        .tag(group.root.path)
                    }
                }
                .onMove(perform: store.moveRepositoryGroups)
            }
        }
        .listStyle(.sidebar)
        .focusedValue(\.repositoryRemoval, RepositoryRemovalAction(
            count: store.selectedRepositoryPaths.count,
            remove: store.removeSelectedRepositories
        ))
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if store.isScanningFolders {
                    ScanActivityView(paths: store.scanningFolderPaths)
                } else if let summary = store.scanSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(summary)
                }
                if store.isAutoFetching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(store.autoPullEnabled ? "Syncing repositories…" : "Fetching remotes…").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .help(store.autoPullEnabled ? "Checking remotes and fast-forwarding eligible default branches" : "Checking remote branches without changing local files")
                }
                HStack(spacing: 14) {
                    Button { store.addRepository() } label: { Label("Add", systemImage: "plus") }
                        .accessibilityLabel("Add Repository")
                        .help("Add a Git repository")
                    Button { store.addScanRoot() } label: { Label("Scan", systemImage: "magnifyingglass") }
                        .accessibilityLabel("Scan Folder")
                        .help("Scan a folder for Git repositories")
                    Menu {
                        if store.scanRoots.isEmpty {
                            Text("No scan folders")
                        } else {
                            ForEach(store.scanRoots, id: \.path) { root in
                                Button("Remove \(root.lastPathComponent)", role: .destructive) {
                                    store.removeScanRoot(root)
                                }
                                .help(root.path)
                            }
                        }
                    } label: {
                        Label("Scan Folders", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Manage automatic scan folders")
                    Spacer(minLength: 0)
                }
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .navigationTitle("Branchline")
    }

    private func checkoutRow(_ repository: Repository, worktree: GitWorktree? = nil) -> some View {
        RepositoryRow(
            name: repository.name, path: repository.path,
            status: store.repositoryStatuses[repository.path],
            error: store.repositoryErrors[repository.path] != nil || store.statusErrors[repository.path] != nil,
            fetchError: store.backgroundFetchErrors[repository.path],
            lastFetched: fetchDate(for: repository),
            backgroundSyncMessage: store.backgroundSyncMessages[repository.path],
            worktree: worktree,
            incoming: { store.showSyncHistory(.incoming, for: repository) },
            outgoing: { store.showSyncHistory(.outgoing, for: repository) }
        )
        .tag(repository.path)
        .contextMenu {
            let targets = store.selectedRepositoryPaths.contains(repository.path)
                ? store.selectedRepositoryPaths : [repository.path]
            Button("Review Local Changes…") { store.showPendingChanges(for: repository) }
            Divider()
            Button("Open in Claude Code") { open(repository, in: .claudeCode) }
            Button("Open in Terminal") { open(repository, in: .terminal) }
            Divider()
            Button(targets.count > 1 ? "Pull Selected (\(targets.count))" : "Pull") { store.perform(.pull, paths: targets) }
                .disabled(store.isOperationRunning)
            Button(targets.count > 1 ? "Stash & Pull Selected (\(targets.count))" : "Stash & Pull") { store.perform(.stashAndPull, paths: targets) }
                .disabled(store.isOperationRunning)
            Button(targets.count > 1 ? "Push Selected (\(targets.count))" : "Push") { store.perform(.push, paths: targets) }
                .disabled(store.isOperationRunning)
            Divider()
            Button("Refresh Status") { Task { await store.refreshStatus(for: repository) } }
            if worktree == nil {
                Button("Refresh Worktrees") { Task { await store.refreshWorktrees(for: repository) } }
                Button("Relocate…") { store.relocateRepository(repository) }
            }
            if let error = store.worktreeErrors[repository.path] { Text(error) }
            Divider()
            Button(targets.count > 1 ? "Remove Selected from Branchline" : "Remove from Branchline", role: .destructive) {
                store.removeRepositories(paths: targets)
            }
        }
    }

    private func fetchDate(for repository: Repository) -> Date? {
        guard let group = store.sidebarGroups.first(where: {
            $0.root.path == repository.path || $0.worktrees.contains { $0.path == repository.path }
        }) else { return store.repositoryFetchDates[repository.path] }
        return ([group.root.path] + group.worktrees.map(\.path))
            .compactMap { store.repositoryFetchDates[$0] }.max()
    }

    private func open(_ repository: Repository, in destination: RepositoryOpener.Destination) {
        Task {
            do { try await RepositoryOpener.open(repository, in: destination) }
            catch { store.globalError = error.localizedDescription }
        }
    }

}

private struct ScanActivityView: View {
    let paths: Set<String>

    private var description: String {
        if paths.count == 1, let path = paths.first {
            return "Scanning \(URL(fileURLWithPath: path).lastPathComponent)…"
        }
        return "Scanning \(paths.count) folders…"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(description).font(.caption).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .help(paths.sorted().joined(separator: "\n"))
    }
}

struct RepositoryRow: View {
    let name: String
    let path: String
    let status: RepositoryStatus?
    let error: Bool
    let fetchError: String?
    let lastFetched: Date?
    var backgroundSyncMessage: String? = nil
    var worktree: GitWorktree? = nil
    var incoming: (() -> Void)? = nil
    var outgoing: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            repositoryIcon
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .help(path)
                        .layoutPriority(1)
                    if let changes = status?.changedFiles, changes > 0 {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .help("\(changes) local changes")
                            .accessibilityLabel("\(changes) local changes")
                    }
                    Spacer(minLength: 0)
                    if let ahead = status?.ahead, ahead > 0 {
                        Button(action: { outgoing?() }) { Label("\(ahead)", systemImage: "arrow.up") }.buttonStyle(.borderless)
                            .help("\(ahead) commits to push")
                            .accessibilityLabel("\(ahead) commits to push")
                    }
                    if let behind = status?.behind, behind > 0 {
                        Button(action: { incoming?() }) { Label("\(behind)", systemImage: "arrow.down") }.buttonStyle(.borderless)
                            .help("\(behind) commits to pull")
                            .accessibilityLabel("\(behind) commits to pull")
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                HStack(spacing: 8) {
                    if let branch = status?.branch ?? worktree?.branch {
                        Text(branch)
                            .fontWeight(branch == status?.defaultBranch ? .bold : .regular)
                            .lineLimit(1)
                            .help(branch == status?.defaultBranch ? "Default branch: \(branch)" : branch)
                    } else {
                        Text(error ? "Unavailable" : status == nil ? "Loading…" : "Detached HEAD")
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    FetchAgeLabel(date: lastFetched)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let worktree, worktree.isLocked || worktree.isPrunable {
                    Text(worktree.isPrunable ? "Unavailable worktree" : "Locked worktree")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(worktree.pruneReason ?? worktree.lockReason ?? "")
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .help([path, backgroundSyncMessage, fetchError.map { "Background sync failed: \($0)" }].compactMap { $0 }.joined(separator: "\n"))
    }

    @ViewBuilder
    private var repositoryIcon: some View {
        if error || fetchError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .accessibilityLabel(error ? "Repository unavailable" : "Background fetch warning")
        } else {
            Image(systemName: worktree == nil ? "folder" : "arrow.triangle.branch")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}

private struct FetchAgeLabel: View {
    let date: Date?

    var body: some View {
        Group {
            if let date {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Fetched \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                }
                .help("Last successful fetch in Branchline: \(date.formatted(date: .abbreviated, time: .standard))")
            } else {
                Text("Not fetched yet")
                    .help("No successful fetch recorded in Branchline yet")
            }
        }
        .lineLimit(1)
        .monospacedDigit()
    }
}
