import SwiftUI
import BranchlineCore

struct CommitInspector: View {
    let store: BranchlineStore
    private var commit: Commit? { store.commits.first { $0.id == store.selectedCommitID } }
    private var associatedRefs: [GitRef] { store.refs.filter { $0.target == store.selectedCommitID } }

    var body: some View {
        Group {
            if let commit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        CommitSummary(commit: commit, refs: associatedRefs)
                        Divider()
                        CommitPeople(commit: commit)
                        Divider()
                        CommitFilesSection(files: store.selectedFiles, isLoading: store.isLoadingFiles, error: store.selectedCommitError, isMerge: commit.parents.count > 1)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select a Commit", systemImage: "info.circle", description: Text("Commit details and changed files appear here."))
            }
        }
        .navigationTitle("Inspector")
    }
}

private struct CommitSummary: View {
    let commit: Commit
    let refs: [GitRef]

    private var messageBody: String {
        let lines = commit.message.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, String(first) == commit.subject else { return commit.message }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.subject).font(.title3.weight(.semibold)).textSelection(.enabled)
            if !messageBody.isEmpty {
                Text(messageBody).font(.callout).textSelection(.enabled)
            }
            Text(commit.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(.secondary)
            if !refs.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(refs) { ref in
                        Text(ref.name).font(.caption2.weight(ref.isDefaultBranch ? .bold : .regular)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            if commit.parents.count > 1 {
                Label("Merge commit · changes shown against first parent", systemImage: "arrow.triangle.merge")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !commit.parents.isEmpty {
                Text("Parents: \(commit.parents.joined(separator: ", "))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct CommitPeople: View {
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            LabeledContent("Author", value: commit.authorName)
            Text(commit.authorEmail).font(.caption).foregroundStyle(.secondary)
            LabeledContent("Authored", value: commit.authorDate.formatted(date: .abbreviated, time: .shortened))
            Divider()
            LabeledContent("Committer", value: commit.committerName)
            Text(commit.committerEmail).font(.caption).foregroundStyle(.secondary)
            LabeledContent("Committed", value: commit.committerDate.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.callout)
    }
}

private struct CommitFilesSection: View {
    let files: [CommitFile]
    let isLoading: Bool
    let error: String?
    let isMerge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changed Files").font(.headline)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else if files.isEmpty {
                Text("No changed files").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(file.status).font(.caption.monospaced()).foregroundStyle(statusColor(file.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).font(.caption).textSelection(.enabled)
                            if let oldPath = file.oldPath { Text("from \(oldPath)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if isMerge {
                Text("File list uses the first parent as the comparison base.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.uppercased().first {
        case "A": .green
        case "D": .red
        case "R", "C": .blue
        default: .secondary
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
