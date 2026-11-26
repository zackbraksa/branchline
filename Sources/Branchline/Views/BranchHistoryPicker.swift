import AppKit
import SwiftUI

struct BranchHistoryPicker: NSViewRepresentable {
    struct Option: Equatable {
        let name: String
        let fullName: String
        let isDefaultBranch: Bool
    }

    let options: [Option]
    let selectedBranch: String?
    let onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel("History filter")
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectBranch(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(button, options: options, selectedBranch: selectedBranch)
    }

    @MainActor final class Coordinator: NSObject {
        private var options: [Option]?
        var onSelect: (String?) -> Void

        init(onSelect: @escaping (String?) -> Void) { self.onSelect = onSelect }

        func update(_ button: NSPopUpButton, options: [Option], selectedBranch: String?) {
            if self.options != options {
                self.options = options
                let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
                let allBranches = NSMenuItem(title: "All branches", action: nil, keyEquivalent: "")
                let branches = options.map { option in
                    let item = NSMenuItem(title: option.name, action: nil, keyEquivalent: "")
                    item.representedObject = option.fullName
                    if option.isDefaultBranch {
                        item.attributedTitle = NSAttributedString(string: option.name, attributes: [.font: font])
                    }
                    return item
                }
                button.menu?.items = [allBranches] + branches
            }
            let index = selectedBranch.map { button.indexOfItem(withRepresentedObject: $0) } ?? 0
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        }

        @objc func selectBranch(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }
            onSelect(item.representedObject as? String)
        }
    }
}
