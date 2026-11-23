import SwiftUI
import BranchlineCore

struct ContentView: View {
    let store: BranchlineStore
    @State private var inspectorVisible = false
    @State private var searchVisible = false
    @State private var searchFocusRequest = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            RepositorySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            RepositoryDetail(store: store, searchVisible: $searchVisible, searchFocusRequest: searchFocusRequest)
                .inspector(isPresented: $inspectorVisible) {
                    CommitInspector(store: store)
                        .inspectorColumnWidth(min: 250, ideal: 330, max: 460)
                }
        }
        .sheet(item: Binding(get: { store.pendingRepository }, set: { store.pendingRepository = $0 })) { repository in
            PendingChangesView(store: store, repository: repository)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Pull All") { store.performBatch(.pull) }
                    .help("Pull latest changes in all saved repositories")
                    .disabled(store.repositories.isEmpty || store.isOperationRunning)
                Button("Stash & Pull All") { store.performBatch(.stashAndPull) }
                    .help("Preserve local changes, pull all saved repositories, then restore changes")
                    .disabled(store.repositories.isEmpty || store.isOperationRunning)

                Button("Push All Eligible") { store.performPushAllEligible() }
                    .help("Refresh remotes, then push clean saved checkouts with outgoing commits and no incoming commits")
                    .disabled(store.repositories.isEmpty || store.isOperationRunning)

                Menu {
                    Button("Fetch Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.fetch) }
                    Button("Pull Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.pull) }
                    Button("Stash & Pull Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.stashAndPull) }
                    Button("Push Selected (\(store.selectedRepositoryPaths.count))") { store.perform(.push) }
                } label: {
                    Label("Selected Repositories", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Fetch, pull or push the \(store.selectedRepositoryPaths.count) selected repositories")
                .disabled(store.selectedRepositoryPaths.isEmpty || store.isOperationRunning)

                Button { store.performBatch(.fetch) } label: {
                    Label("Fetch All", systemImage: "arrow.down.to.line")
                }
                .help("Fetch all saved repositories without pulling changes")
                .disabled(store.repositories.isEmpty || store.isOperationRunning)

                Button {
                    Task { await store.refreshSelectedStatus() }
                } label: { Label("Refresh Status", systemImage: "arrow.clockwise") }
                    .help("Refresh local status")
                    .disabled(store.selectedRepositoryPath == nil)

                Button {
                    inspectorVisible.toggle()
                } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide commit inspector")
            }
        }
        .focusedSceneValue(\.branchlineViewActions, BranchlineViewActions(
            showSearch: { searchVisible = true; searchFocusRequest += 1 },
            toggleInspector: { inspectorVisible.toggle() }
        ))
        .onChange(of: searchVisible) { _, visible in
            if !visible { store.searchText = ""; store.searchCommits("") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshAllStatuses() } }
        }
    }
}
