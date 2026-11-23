import SwiftUI
import AppKit
import BranchlineCore

struct PendingChangesBanner: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("\(count) local file\(count == 1 ? "" : "s")", systemImage: "doc.badge.ellipsis")
                .font(.callout.weight(.medium))
            Text("Review changes before pulling.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Review Changes…", action: review)
        }
        .padding(10)
        .background(.orange.opacity(0.09))
    }
}

private struct DiscardConfirmation: Identifiable {
    let id = UUID()
    let snapshot: PendingChanges
    let paths: Set<String>
}

struct PendingChangesView: View {
    let store: BranchlineStore
    let repository: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmation: DiscardConfirmation?

    private var busy: Bool { store.isOperationRunning || store.isLoadingPending }
    private var selectable: Set<String> {
        Set((store.pendingSnapshot?.files ?? []).filter { $0.unavailableReason == nil }.map(\.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            PendingChangesHeader(name: repository.name, isClean: store.pendingSnapshot?.files.isEmpty == true)
            Divider()
            if let error = store.pendingError {
                Text(error).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let message = store.pendingMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green).padding(12)
            }
            if store.isLoadingPending && store.pendingSnapshot == nil {
                ProgressView("Reading local changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = store.pendingSnapshot {
                if snapshot.files.isEmpty {
                    ContentUnavailableView("No Local Changes", systemImage: "checkmark.circle", description: Text("Your working tree is clean. You can pull the latest commits."))
                } else {
                    List(selection: $selection) {
                        ForEach(snapshot.files) { file in
                            PendingFileRow(file: file, repository: repository)
                                .tag(file.path)
                                .selectionDisabled(file.unavailableReason != nil)
                        }
                    }
                    .listStyle(.inset)
                    .disabled(store.isDiscardingPending)
                }
            } else {
                ContentUnavailableView("Changes Unavailable", systemImage: "exclamationmark.triangle", description: Text("Try refreshing the list."))
            }
            if store.pendingSnapshot?.hasHead == false {
                Text("Discard is unavailable until this repository has its first commit.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            Divider()
            HStack {
                Button(selection == selectable && !selectable.isEmpty ? "Deselect All" : "Select All") {
                    selection = selection == selectable ? [] : selectable
                }
                .disabled(selectable.isEmpty || busy)
                Button("Refresh") { Task { await store.refreshPendingChanges() } }.disabled(busy)
                Spacer()
                if store.isDiscardingPending { ProgressView().controlSize(.small) }
                Button("Discard Selected…", role: .destructive) {
                    guard let snapshot = store.pendingSnapshot else { return }
                    confirmation = DiscardConfirmation(snapshot: snapshot, paths: selection)
                }
                .disabled(selection.isEmpty || busy || store.pendingSnapshot?.hasHead != true)
            }
            .padding(12)
            HStack {
                Text("Discard resets selected files to the last commit, including staged changes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isDiscardingPending)
                Button("Stash & Pull") {
                    dismiss()
                    store.perform(.stashAndPull, paths: [repository.path])
                }
                .help("Keep all local changes, pull, then restore your changes")
                .disabled(busy || store.pendingSnapshot?.hasHead != true || store.pendingSnapshot?.files.isEmpty != false)
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 450, idealHeight: 560)
        .interactiveDismissDisabled(store.isDiscardingPending)
        .onChange(of: store.pendingSnapshot) { _, snapshot in
            selection.formIntersection(Set(snapshot?.files.map(\.path) ?? []))
        }
        .alert(item: $confirmation) { item in
            Alert(
                title: Text("Discard changes in \(item.paths.count) file\(item.paths.count == 1 ? "" : "s")?"),
                message: Text("Selected tracked files return to the last commit. Selected new files are removed. Staged changes are discarded too. A backup of working files and staged changes will be saved in Trash.\n\n" + item.paths.sorted().prefix(5).joined(separator: "\n") + (item.paths.count > 5 ? "\nand \(item.paths.count - 5) more" : "")),
                primaryButton: .destructive(Text("Discard Changes")) {
                    Task { await store.discardPendingChanges(snapshot: item.snapshot, paths: item.paths) }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct PendingChangesHeader: View {
    let name: String
    let isClean: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Local Changes").font(.title2.bold())
            Text(name).font(.headline).foregroundStyle(.secondary)
            Text(isClean ? "Your checkout is ready for a regular pull." : "These files block a regular pull. Keep them with Stash & Pull, or select unwanted changes to discard.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Select a row, or use Command-click and Shift-click for multiple files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }
}

private struct PendingFileRow: View {
    let file: PendingFile
    let repository: Repository

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.indexStatus == "?" ? "doc.badge.plus" : "doc.text")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.path).font(.system(.body, design: .monospaced)).lineLimit(2)
                if let old = file.oldPath { Text("Renamed from \(old)").font(.caption).foregroundStyle(.secondary) }
                Text(file.unavailableReason ?? file.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                var url = URL(fileURLWithPath: repository.path).appendingPathComponent(file.path)
                while !FileManager.default.fileExists(atPath: url.path), url.path != repository.path {
                    url.deleteLastPathComponent()
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal \(file.path) in Finder")
        }
        .padding(.vertical, 4)
        .help(file.path + "\n" + file.summary)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }
}
