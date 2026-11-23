import Foundation
import Testing
@testable import BranchlineCore

extension GitRepositoryTests {
    struct SyncHistoryWorktreeTests {
        @discardableResult
        private func git(_ args: [String], at path: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = path
            let output = Pipe(), error = Pipe()
            process.standardOutput = output; process.standardError = error
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errors = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "Git fixture", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func fixture() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineSync-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: root)
            try git(["config", "user.name", "Test"], at: root)
            try git(["config", "user.email", "test@example.test"], at: root)
            try git(["commit", "--allow-empty", "-m", "base"], at: root)
            return root
        }

        @Test func scopedHistoryAndSearchUseConfiguredUpstream() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["branch", "upstream"], at: root)
            try git(["branch", "--set-upstream-to=upstream", "main"], at: root)
            try git(["commit", "--allow-empty", "-m", "outgoing one"], at: root)
            try git(["commit", "--allow-empty", "-m", "outgoing two"], at: root)
            try git(["switch", "upstream"], at: root)
            try git(["commit", "--allow-empty", "-m", "incoming one"], at: root)
            try git(["switch", "main"], at: root)
            let client = GitClient(), repo = Repository(path: root.path)
            let incoming = try await client.history(repo, limit: 10, scope: .incoming)
            #expect(incoming.commits.map(\.subject) == ["incoming one"])
            let outgoing = try await client.history(repo, limit: 1, scope: .outgoing)
            #expect(outgoing.commits.map(\.subject) == ["outgoing two"])
            #expect(outgoing.hasMore)
            #expect(try await client.search(repo, query: "incoming", scope: .outgoing).isEmpty)
            #expect(try await client.search(repo, query: "incoming", scope: .incoming).count == 1)
            await #expect(throws: GitClientError.self) { try await client.history(repo, limit: 10, branch: "refs/heads/main", scope: .incoming) }
            try git(["branch", "-f", "upstream", "main"], at: root)
            #expect(try await client.history(repo, limit: 10, scope: .incoming).commits.isEmpty)
            #expect(try await client.history(repo, limit: 10, scope: .outgoing).commits.isEmpty)
            try git(["branch", "--unset-upstream"], at: root)
            await #expect(throws: GitClientError.self) { try await client.history(repo, limit: 10, scope: .incoming) }
            try git(["switch", "--detach"], at: root)
            await #expect(throws: GitClientError.self) { try await client.history(repo, limit: 10, scope: .outgoing) }
        }

        @Test func listsLinkedLockedDetachedAndMissingWorktrees() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let parent = root.deletingLastPathComponent()
            let linked = parent.appendingPathComponent("linked space\n\(UUID())")
            let missing = parent.appendingPathComponent("missing \(UUID())")
            defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: missing) }
            try git(["worktree", "add", "--detach", linked.path], at: root)
            try git(["worktree", "lock", "--reason", "reason\nwith spaces", linked.path], at: root)
            try git(["worktree", "add", "--detach", missing.path], at: root)
            try FileManager.default.removeItem(at: missing)
            let client = GitClient(), repo = Repository(path: root.path)
            let trees = try await client.worktrees(repo)
            #expect(trees.count == 3)
            let detached = try #require(trees.first { $0.path == linked.resolvingSymlinksInPath().path })
            #expect(detached.isDetached && detached.isLocked)
            #expect(detached.lockReason == "reason\nwith spaces")
            #expect(detached.head != nil && detached.branch == nil)
            #expect(trees.contains { $0.path.hasSuffix(missing.lastPathComponent) && $0.isPrunable })
            #expect(trees.contains { $0.branch == "main" })
            #expect(try await client.commonDirectory(repo) == client.commonDirectory(Repository(path: linked.path)))
        }
        @Test func bareAndUnbornRepositories() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineBare-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "--bare"], at: root)
            let client = GitClient(), repo = Repository(path: root.path)
            let trees = try await client.worktrees(repo)
            #expect(trees.count == 1 && trees[0].isBare)
            let empty = root.appendingPathComponent("unborn")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try git(["init"], at: empty)
            await #expect(throws: GitClientError.self) {
                try await client.history(Repository(path: empty.path), limit: 10, scope: .incoming)
            }
        }

    }
}
