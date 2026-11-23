import AppKit
import BranchlineCore
import SwiftUI
import Testing
@testable import Branchline

@MainActor
struct GraphTableLayoutTests {
    @Test func tagsHaveTheirOwnBoundedColumnAndBranchesKeepTheirStyles() throws {
        _ = NSApplication.shared
        let longName = String(repeating: "long-tag-", count: 100)
        let refs = [
            ref("main", "refs/heads/main", .localBranch, defaultBranch: true),
            ref("origin/main", "refs/remotes/origin/main", .remoteBranch, defaultBranch: true),
            ref("feature", "refs/heads/feature", .localBranch),
            ref("main", "refs/tags/main", .tag),
            ref(longName, "refs/tags/" + longName, .tag)
        ]
        let host = NSHostingView(rootView: GraphTable(commits: [commit("one"), commit("two")], refs: refs, selection: .constant("one")))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
        host.layoutSubtreeIfNeeded()
        let table = try #require(findTable(host))
        let tags = try #require(table.tableColumns.first { $0.identifier.rawValue == "tags" })
        let description = try #require(table.tableColumns.first { $0.identifier.rawValue == "description" })
        #expect(table.tableColumns.firstIndex(of: tags) == 1)
        #expect(table.tableColumns.firstIndex(of: description) == 2)
        #expect(tags.title.isEmpty)
        #expect(tags.headerCell.accessibilityLabel() == "Tags")
        #expect(tags.width <= 180)
        let longTagWidth = tags.width
        let delegate = try #require(table.delegate)
        let descriptionCell = try #require(delegate.tableView?(table, viewFor: description, row: 0))
        let labels = descendants(descriptionCell).compactMap { $0 as? NSTextField }
        #expect(labels.contains { $0.stringValue == "main" && $0.font?.fontDescriptor.symbolicTraits.contains(.bold) == true })
        #expect(labels.contains { $0.stringValue == "origin/main" && $0.font?.fontDescriptor.symbolicTraits.contains(.bold) == true })
        #expect(labels.contains { $0.stringValue == "feature" && $0.font?.fontDescriptor.symbolicTraits.contains(.bold) == false })
        #expect(descriptionCell.toolTip?.contains("refs/tags/") == false)
        let tagCell = try #require(delegate.tableView?(table, viewFor: tags, row: 0))
        tagCell.frame = NSRect(x: 0, y: 0, width: tags.width, height: 25)
        tagCell.layoutSubtreeIfNeeded()
        #expect(tagCell.toolTip?.contains("refs/tags/main") == true)
        #expect(tagCell.accessibilityLabel()?.contains(longName) == true)
        #expect(descendants(tagCell).compactMap { $0 as? NSTextField }.first?.frame.width ?? 0 <= tags.width - 16)
        let empty = try #require(delegate.tableView?(table, viewFor: tags, row: 1))
        #expect(empty.toolTip == nil)
        #expect(empty.accessibilityLabel() == "No tags")
        #expect(table.selectedRow == 0)
        host.rootView = GraphTable(commits: [commit("one"), commit("two")], refs: Array(refs.dropLast()), selection: .constant("one"))
        host.layoutSubtreeIfNeeded()
        #expect(table.selectedRow == 0)
        #expect(tags.width < longTagWidth)
        #expect(tags.width < 90)
        let fittedCell = try #require(delegate.tableView?(table, viewFor: tags, row: 0))
        fittedCell.frame = NSRect(x: 0, y: 0, width: tags.width, height: 25)
        fittedCell.layoutSubtreeIfNeeded()
        let tagLabel = try #require(descendants(fittedCell).compactMap { $0 as? NSTextField }.first)
        #expect(tagLabel.frame.width >= tagLabel.intrinsicContentSize.width)
    }

    @Test func descriptionFillsAvailableWidthWhenWindowResizes() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GraphTable(commits: [commit("one")], refs: [], selection: .constant(nil)))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 200)
        host.layoutSubtreeIfNeeded()
        let table = try #require(findTable(host))
        let description = try #require(table.tableColumns.first { $0.identifier.rawValue == "description" })
        let author = try #require(table.tableColumns.first { $0.identifier.rawValue == "author" })
        let date = try #require(table.tableColumns.first { $0.identifier.rawValue == "date" })
        let width = description.width
        let authorWidth = author.width
        let dateWidth = date.width
        #expect(abs(table.bounds.width - table.rect(ofColumn: table.numberOfColumns - 1).maxX - table.rect(ofColumn: 0).minX) < 2)
        host.frame.size.width = 1000
        host.layoutSubtreeIfNeeded()
        #expect(description.width < width)
        #expect(author.width == authorWidth)
        #expect(date.width == dateWidth)
        #expect(abs(table.bounds.width - table.rect(ofColumn: table.numberOfColumns - 1).maxX - table.rect(ofColumn: 0).minX) < 2)
    }

    @Test func backgroundHistoryUpdatesPreserveVisibleCommitAndOffset() throws {
        _ = NSApplication.shared
        let commits = (0..<300).map { commit("commit-\($0)") }
        let host = NSHostingView(rootView: GraphTable(commits: commits, refs: [], selection: .constant(commits[0].id)))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        host.layoutSubtreeIfNeeded()
        let table = try #require(findTable(host))
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 100).minY + 7))
        scroll.reflectScrolledClipView(scroll.contentView)
        let row = table.rows(in: table.visibleRect).location
        let visibleID = commits[row].id
        let offset = table.visibleRect.minY - table.rect(ofRow: row).minY

        let updated = [commit("new")] + commits
        host.rootView = GraphTable(commits: updated, refs: [], selection: .constant(commits[0].id))
        host.layoutSubtreeIfNeeded()
        let updatedRow = table.rows(in: table.visibleRect).location
        #expect(updated[updatedRow].id == visibleID)
        #expect(abs(table.visibleRect.minY - table.rect(ofRow: updatedRow).minY - offset) < 1)
        #expect(table.selectedRow == 1)

        host.rootView = GraphTable(commits: updated, refs: [], selection: .constant("new"))
        host.layoutSubtreeIfNeeded()
        #expect(table.selectedRow == 0)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 0)))
    }

    @Test func newestCommitsRemainVisibleWhenAlreadyAtTop() throws {
        _ = NSApplication.shared
        let commits = (0..<100).map { commit("commit-\($0)") }
        let host = NSHostingView(rootView: GraphTable(commits: commits, refs: [], selection: .constant(commits[0].id)))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        host.layoutSubtreeIfNeeded()
        let table = try #require(findTable(host))
        let top = table.visibleRect.minY
        host.rootView = GraphTable(commits: [commit("new")] + commits, refs: [], selection: .constant(commits[0].id))
        host.layoutSubtreeIfNeeded()
        #expect(table.visibleRect.minY == top)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 0)))
        #expect(table.selectedRow == 1)
    }

    @Test func reusedDescriptionCellsKeepBadgeViewsAndUpdateTheirContent() throws {
        _ = NSApplication.shared
        let cell = DescriptionCellView()
        let original = [
            ref("main", "refs/heads/main", .localBranch, defaultBranch: true),
            ref("origin/main", "refs/remotes/origin/main", .remoteBranch),
            ref("feature", "refs/heads/feature", .localBranch)
        ]
        cell.configure(subject: "First", refs: original)
        let stack = try #require(cell.subviews.compactMap { $0 as? NSStackView }.first)
        let badges = stack.arrangedSubviews
        #expect(badges.count == 3)
        let constraintCount = descendants(cell).reduce(0) { $0 + $1.constraints.count }
        for index in 0..<200 {
            cell.configure(subject: "Commit \(index)", refs: [ref("branch-\(index)", "refs/heads/branch-\(index)", .localBranch)])
            cell.configure(subject: "Commit \(index)", refs: original)
        }
        #expect(stack.arrangedSubviews.count == badges.count)
        #expect(zip(stack.arrangedSubviews, badges).allSatisfy { $0 === $1 })
        #expect(descendants(cell).reduce(0) { $0 + $1.constraints.count } == constraintCount)
        cell.configure(subject: "Changed", refs: [ref("other", "refs/heads/other", .localBranch)])
        #expect(badges[0].toolTip == "refs/heads/other")
        let label = try #require(badges[0].subviews.compactMap { $0 as? NSTextField }.first)
        #expect(label.stringValue == "other")
        #expect(label.font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(badges.dropFirst().allSatisfy { $0.isHidden })
    }

    private func ref(_ name: String, _ fullName: String, _ kind: GitRef.Kind, defaultBranch: Bool = false) -> GitRef {
        GitRef(name: name, fullName: fullName, target: "one", kind: kind, isDefaultBranch: defaultBranch)
    }

    private func commit(_ id: String) -> Commit {
        Commit(id: id, parents: [], subject: id, message: id, authorName: "Author", authorEmail: "a@example.com", authorDate: .distantPast, committerName: "Author", committerEmail: "a@example.com", committerDate: .distantPast)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func findTable(_ view: NSView) -> NSTableView? {
        descendants(view).compactMap { $0 as? NSTableView }.first
    }
}
