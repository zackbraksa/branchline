import Foundation

/// A deterministic, prefix-stable layout for a newest-first page of Git history.
/// Lane numbers are assigned as commits and their parents are encountered, so
/// adding older pages does not change the already-laid-out rows.
public struct GraphLayout: Sendable {
    public struct Edge: Hashable, Sendable {
        public let parentID: String
        public let lane: Int
        /// The row is nil when the parent is older than the currently loaded page.
        public let row: Int?

        public init(parentID: String, lane: Int, row: Int?) {
            self.parentID = parentID
            self.lane = lane
            self.row = row
        }
    }

    public struct Row: Sendable {
        public let commitID: String
        public let lane: Int
        public let incomingLanes: [Int]
        /// Existing lines that pass through this row without touching its commit.
        public let continuingLanes: [Int]
        public let parents: [Edge]
        public let laneCount: Int

        public init(commitID: String, lane: Int, incomingLanes: [Int], continuingLanes: [Int], parents: [Edge], laneCount: Int) {
            self.commitID = commitID
            self.lane = lane
            self.incomingLanes = incomingLanes
            self.continuingLanes = continuingLanes
            self.parents = parents
            self.laneCount = laneCount
        }
    }

    public let rows: [Row]

    public init(commits: [Commit]) {
        var laneTargets: [String?] = []
        var indexByID: [String: Int] = [:]
        for (index, commit) in commits.enumerated() { indexByID[commit.id] = index }

        func lane(for target: String, in targets: inout [String?]) -> Int {
            if let existing = targets.firstIndex(where: { $0 == target }) { return existing }
            if let empty = targets.firstIndex(where: { $0 == nil }) {
                targets[empty] = target
                return empty
            }
            targets.append(target)
            return targets.count - 1
        }

        var result: [Row] = []
        result.reserveCapacity(commits.count)

        for commit in commits {
            let incoming = laneTargets.indices.filter { laneTargets[$0] == commit.id }
            let continuing = laneTargets.indices.filter { laneTargets[$0] != nil && laneTargets[$0] != commit.id }
            let nodeLane = incoming.first ?? lane(for: commit.id, in: &laneTargets)
            laneTargets[nodeLane] = nil

            // A merge can have several visible child lines converge on its node.
            // Consume duplicate targets so they cannot leave phantom lanes behind.
            for duplicate in incoming where duplicate != nodeLane { laneTargets[duplicate] = nil }

            var edges: [Edge] = []
            var uniqueParents = Set<String>()
            for parentID in commit.parents where uniqueParents.insert(parentID).inserted {
                let targetLane = lane(for: parentID, in: &laneTargets)
                edges.append(Edge(parentID: parentID, lane: targetLane, row: indexByID[parentID]))
            }

            result.append(Row(
                commitID: commit.id,
                lane: nodeLane,
                incomingLanes: incoming,
                continuingLanes: continuing,
                parents: edges,
                laneCount: max(laneTargets.count, nodeLane + 1)
            ))
        }
        rows = result
    }
}
