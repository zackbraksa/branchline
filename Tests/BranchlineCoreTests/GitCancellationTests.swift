import Darwin
import Foundation
import Testing
@testable import BranchlineCore

private actor FetchCompletion {
    private(set) var finished = false
    private(set) var wasCancelled = false
    private(set) var errorDescription: String?

    func complete(error: Error? = nil) {
        finished = true
        wasCancelled = error is CancellationError
        errorDescription = error?.localizedDescription
    }
}

extension GitRepositoryTests {
    struct GitCancellationTests {
        @discardableResult
        private func git(_ arguments: [String], at directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "GitCancellationTests", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)])
            }
            return String(decoding: data, as: UTF8.self)
        }

        private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if try await condition() { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try await condition()
        }

        @Test(arguments: [false, true])
        func backgroundFetchStopsDescendantsAndReleasesRepositoryLock(timesOut: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineCancellation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], at: root)
            let file = root.appendingPathComponent("tracked.txt")
            try Data("base\n".utf8).write(to: file)
            try git(["add", "tracked.txt"], at: root)
            try git(["-c", "user.name=Branchline Test", "-c", "user.email=branchline@example.test", "commit", "-m", "base"], at: root)
            try Data("staged\n".utf8).write(to: file)
            try git(["add", "tracked.txt"], at: root)
            try Data("unstaged\n".utf8).write(to: file)
            let helper = root.appendingPathComponent("blocked-transport.sh")
            let started = root.appendingPathComponent("started")
            try Data("""
            #!/bin/sh
            trap '' TERM
            /bin/sleep 120 &
            echo "$$ $!" > "$1"
            wait
            """.utf8).write(to: helper)
            try git(["config", "protocol.ext.allow", "always"], at: root)
            try git(["remote", "add", "origin", "ext::/bin/sh \(helper.path) \(started.path)"], at: root)
            let client = GitClient()
            let repo = try await client.validate(path: root.path)
            _ = try await client.status(repo)
            let head = try git(["rev-parse", "HEAD"], at: root)
            let index = try git(["ls-files", "--stage"], at: root)
            let worktree = try Data(contentsOf: file)
            let completion = FetchCompletion()
            let task = Task {
                do {
                    try await client.performBackgroundFetch(on: repo, timeout: timesOut ? 1 : 60)
                    await completion.complete()
                } catch {
                    await completion.complete(error: error)
                }
            }
            var helperPIDs: [pid_t] = []
            defer {
                task.cancel()
                for pid in helperPIDs { kill(pid, SIGKILL) }
            }
            let didStart = try await waitUntil {
                guard let marker = try? String(contentsOf: started, encoding: .utf8) else { return false }
                return marker.split(whereSeparator: \.isWhitespace).count == 2
            }
            try #require(didStart)
            helperPIDs = try String(contentsOf: started, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            try #require(helperPIDs.count == 2)
            #expect(getpgid(helperPIDs[0]) != getpgrp())
            if !timesOut { task.cancel() }
            let finished = try await waitUntil { await completion.finished }
            #expect(finished, "Fetch must finish even when a transport child ignores TERM and holds output pipes open")
            if !finished {
                for pid in helperPIDs { kill(pid, SIGKILL) }
            }
            await task.value
            #expect(await completion.wasCancelled == !timesOut)
            if timesOut {
                #expect(await completion.errorDescription == "Git network operation timed out. Check the remote state before retrying.")
            }
            let descendantsStopped = try await waitUntil { helperPIDs.allSatisfy { kill($0, 0) == -1 } }
            #expect(descendantsStopped)
            #expect(try git(["rev-parse", "HEAD"], at: root) == head)
            #expect(try git(["ls-files", "--stage"], at: root) == index)
            #expect(try Data(contentsOf: file) == worktree)
            try git(["remote", "remove", "origin"], at: root)
            try await client.perform(.fetch, on: repo)
        }
    }
}
