import Foundation
import BranchlineCore

struct OperationResult: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let progress: String
    let error: String?
    let completionSummary: String?
    let outcome: SyncOutcome?

    init(id: String, name: String, progress: String, error: String?, completionSummary: String? = nil, outcome: SyncOutcome? = nil) {
        self.id = id
        self.name = name
        self.progress = progress
        self.error = error
        self.completionSummary = completionSummary
        self.outcome = outcome
    }

    var isFinished: Bool {
        outcome != nil || progress == "Done" || progress == "Failed" || progress == "Cancelled"
    }

    var isSkipped: Bool { outcome == .skipped }
    var isCancelled: Bool { outcome == .cancelled || progress == "Cancelled" }
    var isFailure: Bool { outcome == .failed || (outcome == nil && progress == "Failed") }

    var displayStatus: String {
        error ?? (isFinished ? completionSummary ?? progress : progress)
    }

    static func summary(for operation: GitOperation, status: RepositoryStatus?) -> String {
        let title = "\(operation.title) complete"
        guard let status else { return "\(title) · status unavailable" }
        var details: [String] = []
        if status.upstream == nil {
            details.append("no upstream")
        } else {
            if status.ahead > 0 { details.append("\(status.ahead) to push") }
            if status.behind > 0 { details.append("\(status.behind) to pull") }
            if details.isEmpty { details.append("up to date") }
        }
        if status.changedFiles > 0 {
            details.append("\(status.changedFiles) local \(status.changedFiles == 1 ? "change" : "changes")")
        }
        return ([title] + details).joined(separator: " · ")
    }
}
