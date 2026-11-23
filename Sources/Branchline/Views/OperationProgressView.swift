import SwiftUI
import BranchlineCore

struct OperationProgressView: View {
    let title: String
    let isRunning: Bool
    let results: [OperationResult]
    let cancel: () -> Void
    let dismiss: () -> Void
    var retryFailed: (() -> Void)? = nil

    @State private var isExpanded = true

    private var completedCount: Int { results.filter(\.isFinished).count }
    private var listHeight: CGFloat { CGFloat(min(results.count, 5)) * OperationResultRow.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            OperationProgressHeader(
                title: title,
                completedCount: completedCount,
                totalCount: results.count,
                isRunning: isRunning,
                isExpanded: $isExpanded,
                cancel: cancel,
                dismiss: dismiss,
                retryFailed: retryFailed
            )

            ProgressView(value: Double(completedCount), total: Double(max(results.count, 1)))
                .progressViewStyle(.linear)
                .accessibilityLabel("Operation progress")
                .accessibilityValue("\(completedCount) of \(results.count) repositories complete")

            if isExpanded {
                OperationResultList(results: results)
                    .frame(height: listHeight)
                    .transaction { $0.animation = nil }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45))
        .accessibilityElement(children: .contain)
    }
}

private struct OperationProgressHeader: View {
    let title: String
    let completedCount: Int
    let totalCount: Int
    let isRunning: Bool
    @Binding var isExpanded: Bool
    let cancel: () -> Void
    let dismiss: () -> Void
    var retryFailed: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)

            Text("\(completedCount) of \(totalCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("\(completedCount) of \(totalCount) repositories complete")

            Spacer(minLength: 4)

            if isRunning {
                Button("Cancel", action: cancel)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                if let retryFailed {
                    Button("Retry Failed", action: retryFailed)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse repository progress" : "Expand repository progress")
            .accessibilityLabel(isExpanded ? "Collapse repository progress" : "Expand repository progress")
        }
        .frame(minHeight: 20)
    }
}

private struct OperationResultList: View {
    let results: [OperationResult]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    OperationResultRow(result: result)
                }
            }
        }
        .accessibilityLabel("Repository operation results")
    }
}

private struct OperationResultRow: View {
    static let height: CGFloat = 32

    let result: OperationResult

    @State private var isShowingError = false

    private var shortStatus: String { result.displayStatus }

    var body: some View {
        HStack(spacing: 7) {
            statusIcon
                .frame(width: 20, height: 20)

            Text(result.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
                .help(result.name)

            Text(shortStatus)
                .font(.caption)
                .foregroundStyle(result.error == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(shortStatus)
                .accessibilityLabel("Status: \(shortStatus)")

            if let error = result.error {
                Button("Details") { isShowingError = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .popover(isPresented: $isShowingError) {
                        OperationErrorDetails(error: error)
                    }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if result.outcome == .skipped {
            Image(systemName: "minus.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityLabel("Skipped")
        } else if result.outcome == .cancelled || result.progress == "Cancelled" {
            Image(systemName: "stop.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancelled")
        } else if result.error != nil {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        } else if result.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityLabel("Complete")
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("In progress")
        }
    }
}

private struct OperationErrorDetails: View {
    let error: String

    var body: some View {
        ScrollView {
            Text(error)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(width: 340, height: 180)
        .accessibilityLabel("Full recovery error")
    }
}
