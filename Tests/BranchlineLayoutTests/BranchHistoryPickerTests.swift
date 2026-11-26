import AppKit
import SwiftUI
import Testing
@testable import Branchline

@MainActor
struct BranchHistoryPickerTests {
    @Test func largeMenuPreservesBranchIdentityAndSelection() throws {
        _ = NSApplication.shared
        let local = BranchHistoryPicker.Option(name: "main", fullName: "refs/heads/main", isDefaultBranch: true)
        let remote = BranchHistoryPicker.Option(name: "main", fullName: "refs/remotes/origin/main", isDefaultBranch: false)
        let options = [local, remote] + (0..<1_800).map { index in
            BranchHistoryPicker.Option(name: "branch-\(index)", fullName: "refs/heads/branch-\(index)", isDefaultBranch: false)
        }
        var selection: String? = remote.fullName
        var writes = 0
        func picker(_ options: [BranchHistoryPicker.Option]) -> BranchHistoryPicker {
            BranchHistoryPicker(options: options, selectedBranch: selection) { branch in
                selection = branch
                writes += 1
            }
        }
        let host = NSHostingView(rootView: picker(options))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 30)
        host.layoutSubtreeIfNeeded()

        let button = try #require(findPicker(in: host))
        let defaultItem = try #require(button.item(at: 1))
        let font = defaultItem.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let allItemsEnabled = button.itemArray.allSatisfy(\.isEnabled)
        #expect(button.numberOfItems == options.count + 1)
        #expect(button.indexOfSelectedItem == 2)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(allItemsEnabled)
        #expect(writes == 0)

        let menu = try #require(button.menu)
        menu.performActionForItem(at: 1)
        #expect(selection == local.fullName)
        menu.performActionForItem(at: 0)
        #expect(selection == nil)
        menu.performActionForItem(at: 0)
        #expect(writes == 3)

        selection = local.fullName
        host.rootView = picker(options)
        host.layoutSubtreeIfNeeded()
        #expect(button.item(at: 1) === defaultItem)
        #expect(button.indexOfSelectedItem == 1)
        #expect(writes == 3)

        selection = remote.fullName
        host.rootView = picker([local])
        host.layoutSubtreeIfNeeded()
        #expect(button.numberOfItems == 2)
        #expect(button.selectedItem == nil)
        #expect(selection == remote.fullName)
        #expect(writes == 3)
    }

    private func findPicker(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap { findPicker(in: $0) }.first
    }
}
