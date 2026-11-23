import SwiftUI

struct BranchlineCommands: Commands {
    let store: BranchlineStore
    @ObservedObject var updater: AppUpdater
    @FocusedValue(\.repositoryRemoval) private var repositoryRemoval
    @FocusedValue(\.branchlineViewActions) private var viewActions

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            } else {
                Button("Check for Updates…") {}
                    .disabled(true)
                    .help("Updates are available in the signed release build.")
            }
        }
        CommandGroup(after: .newItem) {
            Button("Add Repository…") { store.addRepository() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Add Scan Folder…") { store.addScanRoot() }
        }
        CommandGroup(after: .toolbar) {
            Button("Search Commits…") { viewActions?.showSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(viewActions == nil || store.selectedRepositoryPath == nil)
            Button("Toggle Commit Inspector") { viewActions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(viewActions == nil)
        }
        CommandMenu("Repository") {
            Button("Pull All") { store.performBatch(.pull) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.repositories.isEmpty || store.isOperationRunning)
            Button("Stash & Pull All") { store.performBatch(.stashAndPull) }
                .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                .disabled(store.repositories.isEmpty || store.isOperationRunning)
            Divider()
            Button("Push All Eligible") { store.performPushAllEligible() }
                .disabled(store.repositories.isEmpty || store.isOperationRunning)
            Button("Retry Failed") { store.retryFailedOperation() }
                .disabled(!store.canRetryFailedOperation)
            Divider()
            Button("Remove Selected Repositories") { repositoryRemoval?.remove() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled((repositoryRemoval?.count ?? 0) == 0)
            Divider()
            Button("Refresh Status") { Task { await store.refreshSelectedStatus() } }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(store.selectedRepositoryPath == nil)
            Divider()
            Group {
                Button("Fetch Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.fetch) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Pull Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.pull) }
                Button("Stash & Pull Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.stashAndPull) }
                Button("Push Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.push) }
            }
            .disabled(store.selectedRepositoryPaths.isEmpty || store.isOperationRunning)
            Divider()
            Button("Fetch All") { store.performBatch(.fetch) }
            Divider()
            Toggle("Automatically Fetch", isOn: Binding(
                get: { store.autoFetchEnabled },
                set: { store.setAutoFetchEnabled($0) }
            ))
            if store.isOperationRunning {
                Divider()
                Button("Cancel Operation") { store.cancelOperation() }
                    .keyboardShortcut(".", modifiers: [.command])
            }
        }
    }
}

struct RepositoryRemovalAction {
    let count: Int
    let remove: @MainActor () -> Void
}

private struct RepositoryRemovalKey: FocusedValueKey {
    typealias Value = RepositoryRemovalAction
}

extension FocusedValues {
    var repositoryRemoval: RepositoryRemovalAction? {
        get { self[RepositoryRemovalKey.self] }
        set { self[RepositoryRemovalKey.self] = newValue }
    }
}

struct BranchlineViewActions {
    let showSearch: @MainActor () -> Void
    let toggleInspector: @MainActor () -> Void
}

private struct BranchlineViewActionsKey: FocusedValueKey {
    typealias Value = BranchlineViewActions
}

extension FocusedValues {
    var branchlineViewActions: BranchlineViewActions? {
        get { self[BranchlineViewActionsKey.self] }
        set { self[BranchlineViewActionsKey.self] = newValue }
    }
}
