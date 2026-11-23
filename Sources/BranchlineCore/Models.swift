import Foundation

public struct Repository: Identifiable, Codable, Hashable, Sendable {
    public var path: String
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(path: String) { self.path = path }
}

public enum HistoryScope: String, Sendable {
    case all, incoming, outgoing
}

public struct GitWorktree: Identifiable, Hashable, Sendable {
    public var path: String
    public var branch: String?
    public var head: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    public var lockReason: String?
    public var pruneReason: String?
    public var id: String { path }

    public init(path: String, branch: String? = nil, head: String? = nil, isBare: Bool = false,
                isDetached: Bool = false, isLocked: Bool = false, isPrunable: Bool = false,
                lockReason: String? = nil, pruneReason: String? = nil) {
        self.path = path; self.branch = branch; self.head = head; self.isBare = isBare
        self.isDetached = isDetached; self.isLocked = isLocked; self.isPrunable = isPrunable
        self.lockReason = lockReason; self.pruneReason = pruneReason
    }
}

public struct GitRef: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case localBranch, remoteBranch, tag, head }
    public var name: String
    public var fullName: String
    public var target: String
    public var kind: Kind
    public var isDefaultBranch: Bool
    public var id: String { fullName }
    public init(name: String, fullName: String, target: String, kind: Kind, isDefaultBranch: Bool = false) {
        self.name = name; self.fullName = fullName; self.target = target; self.kind = kind
        self.isDefaultBranch = isDefaultBranch
    }
}

public struct Commit: Identifiable, Hashable, Sendable {
    public var id: String
    public var parents: [String]
    public var subject: String
    public var message: String
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var committerName: String
    public var committerEmail: String
    public var committerDate: Date
    public init(id: String, parents: [String], subject: String, message: String,
                authorName: String, authorEmail: String, authorDate: Date,
                committerName: String, committerEmail: String, committerDate: Date) {
        self.id = id; self.parents = parents; self.subject = subject; self.message = message
        self.authorName = authorName; self.authorEmail = authorEmail; self.authorDate = authorDate
        self.committerName = committerName; self.committerEmail = committerEmail; self.committerDate = committerDate
    }
}

public struct RepositoryStatus: Equatable, Sendable {
    public var branch: String?
    public var defaultBranch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changedFiles: Int
    public var operationInProgress: Bool
    public init(branch: String? = nil, defaultBranch: String? = nil, upstream: String? = nil, ahead: Int = 0,
                behind: Int = 0, changedFiles: Int = 0, operationInProgress: Bool = false) {
        self.branch = branch; self.defaultBranch = defaultBranch; self.upstream = upstream; self.ahead = ahead; self.behind = behind
        self.changedFiles = changedFiles; self.operationInProgress = operationInProgress
    }
}

public struct CommitFile: Identifiable, Hashable, Sendable {
    public var path: String
    public var oldPath: String?
    public var status: String
    public var id: String { path }
    public init(path: String, oldPath: String? = nil, status: String) {
        self.path = path; self.oldPath = oldPath; self.status = status
    }
}

public struct HistoryPage: Sendable {
    public var commits: [Commit]
    public var refs: [GitRef]
    public var hasMore: Bool
    public init(commits: [Commit], refs: [GitRef], hasMore: Bool) {
        self.commits = commits; self.refs = refs; self.hasMore = hasMore
    }
}

public enum GitOperation: String, CaseIterable, Sendable {
    case fetch, pull, push, stashAndPull

    public var title: String {
        switch self {
        case .stashAndPull: "Stash & Pull"
        default: rawValue.capitalized
        }
    }
}

public enum GitOperationPhase: String, Sendable {
    case savingLocalChanges = "Saving local changes"
    case fetching = "Fetching"
    case pulling = "Pulling"
    case restoringLocalChanges = "Restoring local changes"
    case cleaningUp = "Finishing"
}

public enum SyncMode: Equatable, Sendable {
    case background(autoPull: Bool)
    case pushEligible
}

public enum SyncOutcome: String, Sendable {
    case updated, upToDate, skipped, failed, cancelled
}

public enum SyncSkipReason: String, Sendable {
    case localChanges, busy, detached, missingUpstream, localUpstream, unknownDefaultBranch
    case featureBranch, diverged, incomingCommits, outgoingCommits, unavailable
    case checkoutChanged, ambiguousPushTarget, remoteCheckFailed

    public var description: String {
        switch self {
        case .localChanges: "Local changes"
        case .busy: "Git operation in progress"
        case .detached: "Detached HEAD"
        case .missingUpstream: "No supported upstream"
        case .localUpstream: "Local-only upstream"
        case .unknownDefaultBranch: "Default branch unknown"
        case .featureBranch: "Feature branch"
        case .diverged: "Diverged"
        case .incomingCommits: "Incoming commits"
        case .outgoingCommits: "Outgoing commits"
        case .unavailable: "Checkout unavailable"
        case .checkoutChanged: "Checkout changed during preparation"
        case .ambiguousPushTarget: "Multiple checkouts target the same remote branch"
        case .remoteCheckFailed: "Remote check failed"
        }
    }
}

public struct RepositorySyncResult: Sendable, Equatable {
    public let repository: Repository
    public let outcome: SyncOutcome
    public let reason: SyncSkipReason?
    public let message: String?
    public let fetched: Bool

    public init(repository: Repository, outcome: SyncOutcome, reason: SyncSkipReason? = nil,
                message: String? = nil, fetched: Bool = false) {
        self.repository = repository; self.outcome = outcome; self.reason = reason
        self.message = message; self.fetched = fetched
    }
}
