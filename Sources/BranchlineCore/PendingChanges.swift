import Foundation

public struct PendingFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let oldPath: String?
    public let indexStatus: String
    public let worktreeStatus: String
    public let unavailableReason: String?
    public var id: String { path }
    public var paths: [String] { [path] + (oldPath.map { [$0] } ?? []) }
    public var summary: String {
        if indexStatus == "?" { return "Untracked" }
        if unavailableReason != nil { return indexStatus == "U" || worktreeStatus == "U" ? "Conflict" : "Review externally" }
        let kind = oldPath != nil ? "Renamed" : indexStatus == "A" ? "Added" : indexStatus == "D" || worktreeStatus == "D" ? "Deleted" : "Modified"
        let stage = indexStatus != "." && worktreeStatus != "." ? "Staged + unstaged" : indexStatus != "." ? "Staged" : "Unstaged"
        return "\(kind) · \(stage)"
    }
}

public struct PendingChanges: Equatable, Sendable {
    public let files: [PendingFile]
    public let fingerprint: Data
    public let hasHead: Bool
}
