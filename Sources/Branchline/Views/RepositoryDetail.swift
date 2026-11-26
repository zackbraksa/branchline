import SwiftUI
import BranchlineCore

struct RepositoryDetail: View {
    let store: BranchlineStore
    @Binding var searchVisible: Bool
    let searchFocusRequest: Int
    @FocusState private var searchFocused: Bool
    @State private var selectedSearchResult: String?

    private var selectedCommit: Commit? { store.commits.first { $0.id == store.selectedCommitID } }
    private var branchOptions: [BranchHistoryPicker.Option] {
        let includeRemotes = store.includeRemotes
        return store.refs.compactMap { ref in
            guard ref.kind == .localBranch || (includeRemotes && ref.kind == .remoteBranch) else { return nil }
            return BranchHistoryPicker.Option(name: ref.name, fullName: ref.fullName, isDefaultBranch: ref.isDefaultBranch)
        }
    }

    private var retryFailedAction: (() -> Void)? {
        guard store.canRetryFailedOperation else { return nil }
        return { store.retryFailedOperation() }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.showsOperationResults {
                OperationProgressView(
                    title: store.operationDescription ?? "Working",
                    isRunning: store.isOperationRunning,
                    results: store.operationResults,
                    cancel: store.cancelOperation,
                    dismiss: store.dismissOperationResults,
                    retryFailed: retryFailedAction
                )
            }
            if let message = store.globalError {
                DismissibleErrorBanner(message: message) { store.dismissGlobalError() }
            }
            if let message = store.selectedRepositoryPath.flatMap({ store.repositoryErrors[$0] ?? store.statusErrors[$0] }) {
                ErrorBanner(message: message)
            }
            if let repository = store.selectedRepository,
               let status = store.repositoryStatuses[repository.path], status.changedFiles > 0 {
                PendingChangesBanner(count: status.changedFiles, review: { store.showPendingChanges(for: repository) })
            }
            if store.selectedRepositoryPath == nil {
                EmptyRepositoryView(addRepository: store.addRepository, addScanRoot: store.addScanRoot)
            } else {
                historyContent
            }
        }
        .navigationTitle(store.selectedRepository?.name ?? "Branchline")
        .onChange(of: searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: selectedSearchResult) { _, value in
            guard let value, let commit = store.searchResults.first(where: { $0.id == value }) else { return }
            store.revealSearchResult(commit)
        }
        .onChange(of: store.searchResults.map(\.id)) { _, _ in
            if !store.searchResults.contains(where: { $0.id == selectedSearchResult }) { selectedSearchResult = nil }
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("History filter").accessibilityHidden(true)
                    BranchHistoryPicker(options: branchOptions, selectedBranch: store.branchFilter, onSelect: store.setBranch)
                }
                .frame(maxWidth: 220)
                Toggle("Remotes", isOn: Binding(get: { store.includeRemotes }, set: { _ in store.toggleRemoteHistory() }))
                    .toggleStyle(.checkbox)
                Spacer()
                if let status = store.selectedRepositoryPath.flatMap({ store.repositoryStatuses[$0] }) {
                    Text(status.branch ?? "Detached HEAD").font(.caption.weight(status.branch != nil && status.branch == status.defaultBranch ? .bold : .regular)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if searchVisible {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search commits", text: Binding(
                        get: { store.searchText },
                        set: { store.searchText = $0; store.searchCommits($0) }
                    ))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { searchVisible = false }
                    Button { searchVisible = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Close commit search")
                        .accessibilityLabel("Close commit search")
                }
                .padding(10)
                .task { searchFocused = true }
                Divider()
            }

            if store.historyScope != .all {
                HStack {
                    Text(store.historyScope == .incoming ? "Incoming commits" : "Outgoing commits")
                        .font(.callout.weight(.medium))
                    if let path = store.selectedRepositoryPath, let upstream = store.repositoryStatuses[path]?.upstream {
                        Text("vs. \(upstream)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Full History") { store.showAllHistory() }.buttonStyle(.borderless)
                }
                .padding(10)
                Divider()
            }

            if store.commits.isEmpty, store.isLoadingHistory {
                ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.commits.isEmpty, store.searchText.isEmpty {
                ContentUnavailableView(
                    store.selectedRepositoryPath.flatMap { store.repositoryErrors[$0] } != nil ? "History Unavailable" : store.historyScope == .incoming ? "No Incoming Commits" : store.historyScope == .outgoing ? "No Outgoing Commits" : "No Commits",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("History is shown relative to this checkout's upstream when filtering incoming or outgoing commits.")
                )
            } else if !store.searchText.isEmpty {
                SearchResultsView(results: store.searchResults, selection: $selectedSearchResult)
            } else {
                GraphTable(commits: store.commits, refs: store.refs, selection: Binding(get: { store.selectedCommitID }, set: { store.selectedCommitID = $0 }))
            }

            if store.hasMoreHistory {
                Divider()
                HStack {
                    Text("Showing \(store.commits.count) commits")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Load More") { store.loadMoreHistory() }
                        .disabled(store.isLoadingHistory)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
    }
}

private struct EmptyRepositoryView: View {
    let addRepository: () -> Void
    let addScanRoot: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Repositories", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Add a local Git repository or scan a folder you choose.")
        } actions: {
            HStack {
                Button("Add Repository…", action: addRepository).buttonStyle(.borderedProminent)
                Button("Scan Folder…", action: addScanRoot).buttonStyle(.bordered)
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.13))
    }
}

private struct DismissibleErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.13))
    }
}

private struct SearchResultsView: View {
    let results: [Commit]
    @Binding var selection: String?

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "magnifyingglass", description: Text("Search commit messages, authors, or hashes."))
        } else {
            List(selection: $selection) {
                ForEach(results) { commit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commit.subject).lineLimit(1)
                        HStack {
                            Text(commit.authorName)
                            Text(String(commit.id.prefix(10))).font(.system(.caption, design: .monospaced))
                            Text(commit.authorDate, format: .dateTime.year().month().day())
                        }.font(.caption).foregroundStyle(.secondary)
                    }.tag(commit.id)
                }
            }.listStyle(.inset)
        }
    }
}
