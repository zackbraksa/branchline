import SwiftUI

struct SettingsView: View {
    let store: BranchlineStore

    var body: some View {
        Form {
            Section("Background updates") {
                Toggle("Automatically fetch repositories", isOn: Binding(
                    get: { store.autoFetchEnabled },
                    set: { store.setAutoFetchEnabled($0) }
                ))
                Picker("Fetch every", selection: Binding(
                    get: { store.autoFetchIntervalMinutes },
                    set: { store.setAutoFetchIntervalMinutes($0) }
                )) {
                    ForEach(BranchlineStore.allowedAutoFetchIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : minutes == 60 ? "1 hour" : "\(minutes) minutes")
                            .tag(minutes)
                    }
                }
                .disabled(!store.autoFetchEnabled)
                Toggle("Automatically pull default branches", isOn: Binding(
                    get: { store.autoPullEnabled },
                    set: { store.setAutoPullEnabled($0) }
                ))
                .disabled(!store.autoFetchEnabled)
                Text("After fetching, fast-forward clean saved checkouts on their detected default branch. Local changes, feature branches and diverged branches are skipped. Never stashes or pushes automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sync concurrency") {
                Stepper(value: Binding(
                    get: { store.manualOperationConcurrency },
                    set: { store.setManualOperationConcurrency($0) }
                ), in: BranchlineStore.manualOperationConcurrencyRange) {
                    HStack {
                        Text("Repositories in parallel")
                        Spacer()
                        Text("\(store.manualOperationConcurrency)")
                            .monospacedDigit()
                    }
                }
                Text("Applies to background checks and manual operations. Linked worktrees share one sync slot. A running batch keeps its current limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
    }
}
