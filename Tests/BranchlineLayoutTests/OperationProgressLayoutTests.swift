import AppKit
import SwiftUI
import Testing
@testable import Branchline

@MainActor
struct OperationProgressLayoutTests {
    @Test func longErrorsAndStatusUpdatesKeepThePanelHeightStable() {
        _ = NSApplication.shared
        let waiting = makeResults(progress: "Waiting", error: nil)
        let host = NSHostingView(rootView: panel(results: waiting, running: true, width: 650))
        host.layoutSubtreeIfNeeded()
        let before = host.fittingSize
        #expect(before.height > 0 && before.height <= 240)

        let error = String(repeating: "Local changes are backed up. Resolve conflicts before retrying.\n", count: 100)
        host.rootView = panel(results: makeResults(progress: "Failed", error: error), running: false, width: 650)
        host.layoutSubtreeIfNeeded()
        let after = host.fittingSize
        #expect(after.height <= 240)
        #expect(abs(after.height - before.height) < 1)
    }

    @Test func narrowPanelStaysBoundedWithManyLongRepositoryNames() {
        _ = NSApplication.shared
        let results = makeResults(progress: "Restoring local changes", error: nil)
        let host = NSHostingView(rootView: panel(results: results, running: true, width: 390))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0 && host.fittingSize.height <= 240)
        #expect(host.fittingSize.width <= 390)
    }

    @Test func retryActionKeepsCompletedPanelBounded() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView:
            OperationProgressView(title: "Push All Eligible", isRunning: false,
                                  results: makeResults(progress: "Failed", error: "Remote check failed"),
                                  cancel: {}, dismiss: {}, retryFailed: {})
                .frame(width: 390)
        )
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= 240)
        #expect(host.fittingSize.width <= 390)
    }

    private func makeResults(progress: String, error: String?) -> [OperationResult] {
        (0..<100).map {
            OperationResult(id: "/tmp/repo-\($0)", name: "repository-with-a-long-name-\($0)", progress: progress, error: error)
        }
    }

    private func panel(results: [OperationResult], running: Bool, width: CGFloat) -> some View {
        OperationProgressView(title: "Stash & Pull", isRunning: running, results: results, cancel: {}, dismiss: {})
            .frame(width: width)
    }
}
