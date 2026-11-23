import XCTest
@testable import BranchlineCore

final class GraphLayoutTests: XCTestCase {
    func testMergeAndOctopusEdgesPointToOlderRows() {
        let commits = [
            commit("merge", parents: ["left", "right", "third"]),
            commit("third", parents: ["root"]),
            commit("left", parents: ["root"]),
            commit("right", parents: ["root"]),
            commit("root", parents: [])
        ]

        let layout = GraphLayout(commits: commits)
        XCTAssertEqual(layout.rows.count, commits.count)
        XCTAssertEqual(layout.rows[0].parents.map(\.parentID), ["left", "right", "third"])
        for (rowIndex, row) in layout.rows.enumerated() {
            for edge in row.parents {
                XCTAssertEqual(edge.row, commits.firstIndex(where: { $0.id == edge.parentID }))
                if let targetRow = edge.row { XCTAssertGreaterThan(targetRow, rowIndex) }
            }
        }
    }

    func testMissingParentsContinueAsUnloadedEdgesAndKeepLaneColorsWhenAppending() {
        let firstPage = [commit("tip", parents: ["branch", "base"]), commit("branch", parents: ["base"])]
        let secondPage = firstPage + [commit("base", parents: ["root"]), commit("root", parents: [])]

        let first = GraphLayout(commits: firstPage)
        let paged = GraphLayout(commits: secondPage)
        XCTAssertEqual(first.rows[0].parents.map(\.lane), paged.rows[0].parents.map(\.lane))
        XCTAssertEqual(first.rows[1].lane, paged.rows[1].lane)
        XCTAssertNil(first.rows[0].parents[1].row)
        XCTAssertEqual(paged.rows[0].parents[1].row, 2)
        XCTAssertNil(first.rows[1].parents[0].row)
        XCTAssertEqual(paged.rows[1].parents[0].row, 2)
    }

    func testDisconnectedRootsGetDistinctStableLanes() {
        let commits = [commit("new-root", parents: []), commit("old-root", parents: [])]
        let layout = GraphLayout(commits: commits)
        XCTAssertTrue(layout.rows.allSatisfy(\.parents.isEmpty))
        XCTAssertEqual(layout.rows.map(\.commitID), ["new-root", "old-root"])
    }

    func testOtherBranchLineContinuesAcrossRows() {
        let commits = [
            commit("tip", parents: ["a", "b"]),
            commit("b", parents: ["base"]),
            commit("a", parents: ["base"]),
            commit("base", parents: [])
        ]
        let layout = GraphLayout(commits: commits)
        let aLane = layout.rows[0].parents[0].lane
        XCTAssertEqual(layout.rows[1].commitID, "b")
        XCTAssertTrue(layout.rows[1].continuingLanes.contains(aLane))
        XCTAssertEqual(layout.rows[2].lane, aLane)
    }

    private func commit(_ id: String, parents: [String]) -> Commit {
        Commit(id: id, parents: parents, subject: id, message: id,
               authorName: "Author", authorEmail: "author@example.com", authorDate: .distantPast,
               committerName: "Author", committerEmail: "author@example.com", committerDate: .distantPast)
    }
}
