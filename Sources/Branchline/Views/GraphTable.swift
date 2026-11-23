import AppKit
import BranchlineCore
import SwiftUI

public struct GraphTable: NSViewRepresentable {
    public let commits: [Commit]
    public let refs: [GitRef]
    @Binding public var selection: String?

    public init(commits: [Commit], refs: [GitRef], selection: Binding<String?>) {
        self.commits = commits
        self.refs = refs
        self._selection = selection
    }

    public func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    public func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let graph = NSTableColumn(identifier: .graph)
        graph.title = "Graph"
        graph.width = 110
        graph.minWidth = 80
        graph.maxWidth = 1400
        graph.resizingMask = .userResizingMask
        table.addTableColumn(graph)

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat)] = [
            (.tags, "", 16, 16),
            (.description, "Description", 340, 180),
            (.author, "Author", CGFloat(120), CGFloat(90)),
            (.date, "Date", CGFloat(140), CGFloat(100))
        ]
        for (identifier, title, width, minWidth) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minWidth
            if identifier == .tags {
                column.maxWidth = 180
                column.resizingMask = []
                column.headerCell.setAccessibilityLabel("Tags")
            } else if identifier == .description {
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                column.resizingMask = .userResizingMask
            }
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        context.coordinator.update(commits: commits, refs: refs, selection: $selection)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(commits: commits, refs: refs, selection: $selection)
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.dataSource = nil
        coordinator.table?.delegate = nil
    }

    @MainActor public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate weak var table: NSTableView?
        private var commits: [Commit] = []
        private var refs: [GitRef] = []
        private var graph = GraphLayout(commits: [])
        private var rowIndices: [String: Int] = [:]
        private var presentations: [RowPresentation] = []
        private var dateLabels: [Date: DateLabels] = [:]
        private let isoDateFormatter = ISO8601DateFormatter()
        private var selection: Binding<String?>
        private var suppressSelectionEvents = false
        private var lastRequestedSelection: String?
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        private struct DateLabels {
            let display: String
            let tooltip: String
        }

        private struct RowPresentation {
            let branches: [GitRef]
            let tags: [GitRef]
            let date: DateLabels
            let tooltip: String
            let accessibilityLabel: String
        }

        fileprivate init(selection: Binding<String?>) { self.selection = selection }

        fileprivate func update(commits newCommits: [Commit], refs newRefs: [GitRef], selection: Binding<String?>) {
            self.selection = selection
            guard commits != newCommits || refs != newRefs else {
                synchronizeSelection(selection.wrappedValue)
                return
            }
            let selectedID = self.selection.wrappedValue
            let anchor = selectedID == lastRequestedSelection ? visibleAnchor() : nil
            let commitsChanged = commits != newCommits
            commits = newCommits
            refs = newRefs
            if commitsChanged {
                graph = GraphLayout(commits: newCommits)
                rowIndices = Dictionary(uniqueKeysWithValues: newCommits.enumerated().map { ($0.element.id, $0.offset) })
            }
            let branchesByCommit = Dictionary(grouping: newRefs.filter { $0.kind != .tag }, by: \.target)
            let tagsByCommit = Dictionary(grouping: newRefs.filter { $0.kind == .tag }, by: \.target)
            var nextDateLabels: [Date: DateLabels] = [:]
            presentations = newCommits.map { commit in
                let labels = branchesByCommit[commit.id] ?? []
                let date = nextDateLabels[commit.authorDate] ?? dateLabels[commit.authorDate] ?? DateLabels(
                    display: dateFormatter.string(from: commit.authorDate),
                    tooltip: isoDateFormatter.string(from: commit.authorDate)
                )
                nextDateLabels[commit.authorDate] = date
                return RowPresentation(
                    branches: labels, tags: tagsByCommit[commit.id] ?? [], date: date,
                    tooltip: ([commit.subject] + labels.map(\.fullName)).joined(separator: " · "),
                    accessibilityLabel: "\(commit.subject), commit \(commit.id), " + labels.map(\.fullName).joined(separator: ", ")
                )
            }
            dateLabels = nextDateLabels
            suppressSelectionEvents = true
            if let tagsColumn = table?.tableColumns.first(where: { $0.identifier == .tags }) {
                let commitIDs = Set(commits.map(\.id))
                let tags = tagsByCommit.filter { commitIDs.contains($0.key) }
                let font = NSFont.systemFont(ofSize: 10, weight: .medium)
                let width = tags.values.map { labels in
                    ceil((labels.map(\.name).joined(separator: ", ") as NSString).size(withAttributes: [.font: font]).width) + 28
                }.max() ?? 16
                tagsColumn.width = min(180, max(16, width))
            }
            table?.reloadData()
            synchronizeSelection(selectedID, force: commitsChanged)
            if let anchor, let row = rowIndices[anchor.id], let table, let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                let origin = NSPoint(x: anchor.x, y: table.rect(ofRow: row).minY + anchor.offset)
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                scroll.reflectScrolledClipView(clip)
            }
            suppressSelectionEvents = false
        }

        public func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard commits.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
            let commit = commits[row]
            let presentation = presentations[row]
            if identifier == .graph {
                let cell = tableView.makeView(withIdentifier: .graphCell, owner: self) as? GraphCellView ?? GraphCellView()
                cell.identifier = .graphCell
                cell.row = graph.rows[row]
                return cell
            }

            if identifier == .description {
                let cell = tableView.makeView(withIdentifier: .descriptionCell, owner: self) as? DescriptionCellView ?? DescriptionCellView()
                cell.identifier = .descriptionCell
                cell.configure(subject: commit.subject, refs: presentation.branches)
                cell.toolTip = presentation.tooltip
                cell.setAccessibilityLabel(presentation.accessibilityLabel)
                return cell
            }

            if identifier == .tags {
                let cell = tableView.makeView(withIdentifier: .tagsCell, owner: self) as? TagsCellView ?? TagsCellView()
                cell.identifier = .tagsCell
                cell.configure(refs: presentation.tags)
                return cell
            }

            let textCell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeTextCell(identifier: identifier)
            textCell.identifier = identifier
            switch identifier {
            case .author:
                textCell.textField?.stringValue = commit.authorName
                textCell.toolTip = "\(commit.authorName) <\(commit.authorEmail)>"
            case .date:
                textCell.textField?.stringValue = presentation.date.display
                textCell.toolTip = presentation.date.tooltip
            case .commit:
                textCell.textField?.stringValue = String(commit.id.prefix(10))
                textCell.toolTip = commit.id
                textCell.setAccessibilityLabel("Commit \(commit.id)")
            default:
                break
            }
            return textCell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionEvents else { return }
            guard let table, table.selectedRow >= 0, commits.indices.contains(table.selectedRow) else {
                selection.wrappedValue = nil
                return
            }
            let selectedID = commits[table.selectedRow].id
            if selection.wrappedValue != selectedID { selection.wrappedValue = selectedID }
        }

        private func visibleAnchor() -> (id: String, offset: CGFloat, x: CGFloat)? {
            guard let table, table.visibleRect.minY > table.bounds.minY else { return nil }
            let row = table.rows(in: table.visibleRect).location
            guard commits.indices.contains(row) else { return nil }
            return (commits[row].id, table.visibleRect.minY - table.rect(ofRow: row).minY, table.visibleRect.minX)
        }

        private func synchronizeSelection(_ id: String?, force: Bool = false) {
            guard let table else { return }
            let row = id.flatMap { rowIndices[$0] } ?? -1
            if force || table.selectedRow != row {
                if row >= 0 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                else { table.deselectAll(nil) }
            }
            if id != lastRequestedSelection, row >= 0 { table.scrollRowToVisible(row) }
            lastRequestedSelection = id
        }

        private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.identifier = identifier
            return cell
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let graph = Self("graph")
    static let description = Self("description")
    static let tags = Self("tags")
    static let author = Self("author")
    static let date = Self("date")
    static let commit = Self("commit")
    static let graphCell = Self("graph-cell")
    static let descriptionCell = Self("description-cell")
    static let tagsCell = Self("tags-cell")
}

private final class GraphCellView: NSTableCellView {
    var row: GraphLayout.Row? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(row.map { "Commit graph, lane \($0.lane + 1)" })
        }
    }
    private let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemRed, .systemTeal, .systemPink, .systemBrown]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row else { return }
        let spacing: CGFloat = 14
        let left: CGFloat = 12
        func x(_ lane: Int) -> CGFloat { left + (CGFloat(lane) + 0.5) * spacing }
        func stroke(from start: NSPoint, to end: NSPoint, lane: Int) {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            colors[lane % colors.count].setStroke()
            path.move(to: start)
            if start.x == end.x {
                path.line(to: end)
            } else {
                let bend = (end.y - start.y) * 0.5
                path.curve(to: end,
                           controlPoint1: NSPoint(x: start.x, y: start.y + bend),
                           controlPoint2: NSPoint(x: end.x, y: end.y - bend))
            }
            path.stroke()
        }
        for lane in row.incomingLanes {
            stroke(from: NSPoint(x: x(lane), y: bounds.maxY),
                   to: NSPoint(x: x(row.lane), y: bounds.midY), lane: lane)
        }
        for lane in row.continuingLanes {
            stroke(from: NSPoint(x: x(lane), y: bounds.maxY),
                   to: NSPoint(x: x(lane), y: bounds.minY), lane: lane)
        }
        for edge in row.parents {
            stroke(from: NSPoint(x: x(row.lane), y: bounds.midY),
                   to: NSPoint(x: x(edge.lane), y: bounds.minY), lane: edge.lane)
        }
        colors[row.lane % colors.count].setFill()
        NSBezierPath(ovalIn: NSRect(x: x(row.lane) - 4, y: bounds.midY - 4, width: 8, height: 8)).fill()
    }
}

final class DescriptionCellView: NSTableCellView {
    private let subjectLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private var badges: [BranchBadgeView] = []
    private var configuredRefs: [GitRef]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        subjectLabel.font = .systemFont(ofSize: 12)
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeStack.orientation = .horizontal
        badgeStack.alignment = .centerY
        badgeStack.spacing = 4
        badgeStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [subjectLabel, badgeStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            subjectLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeStack.leadingAnchor.constraint(equalTo: subjectLabel.trailingAnchor, constant: 8),
            badgeStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            badgeStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(subject: String, refs: [GitRef]) {
        subjectLabel.stringValue = subject
        guard configuredRefs != refs else { return }
        configuredRefs = refs
        while badges.count < refs.count {
            let badge = BranchBadgeView()
            badges.append(badge)
            badgeStack.addArrangedSubview(badge)
        }
        for (index, badge) in badges.enumerated() {
            badge.isHidden = index >= refs.count
            if index < refs.count { badge.configure(refs[index]) }
        }
    }
}

private final class BranchBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.14).cgColor
        layer?.cornerRadius = 4
        label.textColor = .systemBlue
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ ref: GitRef) {
        label.stringValue = ref.name
        label.font = .systemFont(ofSize: 10, weight: ref.isDefaultBranch ? .bold : .medium)
        toolTip = ref.fullName
        setAccessibilityLabel("Branch: \(ref.fullName)")
    }
}

private final class TagsCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let badge = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemOrange
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(refs: [GitRef]) {
        label.stringValue = refs.map(\.name).joined(separator: ", ")
        badge.isHidden = refs.isEmpty
        let names = refs.map(\.fullName).joined(separator: ", ")
        toolTip = refs.isEmpty ? nil : names
        setAccessibilityLabel(refs.isEmpty ? "No tags" : "Tags: " + names)
    }
}
