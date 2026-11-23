import Foundation
import Testing
@testable import BranchlineCore

extension GitRepositoryTests {
    struct StashPullTests {
        private struct Fixture {
            let root: URL
            let remote: URL
            let repo: URL
            let peer: URL
        }

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineStashPull-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        @discardableResult
        private func git(_ arguments: [String], at directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "StashPullTests.Git",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)]
                )
            }
            return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func write(_ contents: String, to relativePath: String, in directory: URL) throws {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        private func read(_ relativePath: String, in directory: URL) throws -> String {
            String(decoding: try Data(contentsOf: directory.appendingPathComponent(relativePath)), as: UTF8.self)
        }

        private func commit(_ message: String, in directory: URL) throws {
            try git(["add", "-A"], at: directory)
            try git(["-c", "user.name=Branchline Test", "-c", "user.email=branchline@example.test", "commit", "-m", message], at: directory)
        }

        private func fixture() throws -> Fixture {
            let root = try temporaryDirectory()
            let remote = root.appendingPathComponent("remote.git")
            let repo = root.appendingPathComponent("repo")
            let peer = root.appendingPathComponent("peer")
            try git(["init", "--bare", remote.path], at: root)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repo)
            try git(["config", "user.name", "Branchline Test"], at: repo)
            try git(["config", "user.email", "branchline@example.test"], at: repo)
            try write("base\n", to: "shared.txt", in: repo)
            try write("existing base\n", to: "existing.txt", in: repo)
            try write("ignored/\n", to: ".gitignore", in: repo)
            try commit("base", in: repo)
            try git(["remote", "add", "origin", remote.path], at: repo)
            try git(["push", "-u", "origin", "main"], at: repo)
            try git(["clone", "--branch", "main", remote.path, peer.path], at: root)
            try git(["config", "user.name", "Branchline Peer"], at: peer)
            try git(["config", "user.email", "peer@example.test"], at: peer)
            return Fixture(root: root, remote: remote, repo: repo, peer: peer)
        }

        private func stashEntries(in directory: URL) throws -> [String] {
            let value = try git(["stash", "list", "--format=%H"], at: directory)
            return value.isEmpty ? [] : value.components(separatedBy: "\n")
        }

        @Test func cleanRepositoryFastForwardsWithoutCreatingStash() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("remote addition\n", to: "remote.txt", in: fixture.peer)
            try commit("remote addition", in: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            let stashBefore = try stashEntries(in: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            try await client.perform(.stashAndPull, on: repository)

            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) != headBefore)
            #expect(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("remote.txt").path))
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func pullsAndRestoresStagedUnstagedUntrackedAndPreexistingStash() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            try write("older local edit\n", to: "existing.txt", in: fixture.repo)
            try git(["stash", "push", "-m", "preexisting"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            try write("remote addition\n", to: "remote.txt", in: fixture.peer)
            try commit("remote addition", in: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)

            try write("staged version\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("unstaged version\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            try write("ignored local data\n", to: "ignored/cache.txt", in: fixture.repo)
            let stagedBefore = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let unstagedBefore = try git(["diff", "--binary"], at: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            try await client.perform(.stashAndPull, on: repository)

            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == stagedBefore)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == unstagedBefore)
            #expect(try read("shared.txt", in: fixture.repo) == "unstaged version\n")
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try read("ignored/cache.txt", in: fixture.repo) == "ignored local data\n")
            #expect(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("remote.txt").path))
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func restoreConflictKeepsOwnedStashAndReportsUsefulError() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("local conflicting version\n", to: "shared.txt", in: fixture.repo)
            try write("remote conflicting version\n", to: "shared.txt", in: fixture.peer)
            try commit("remote conflicting edit", in: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            let stashBefore = try stashEntries(in: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            do {
                try await client.perform(.stashAndPull, on: repository)
                Issue.record("Expected restoring the local edit to report a conflict")
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!message.isEmpty)
                #expect(message.localizedCaseInsensitiveContains("stash") || message.localizedCaseInsensitiveContains("conflict"))
            }

            let stashAfter = try stashEntries(in: fixture.repo)
            #expect(stashAfter.count == stashBefore.count + 1)
            #expect(Array(stashAfter.dropFirst()) == stashBefore)
            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == git(["rev-parse", "origin/main"], at: fixture.repo))
        }

        @Test func failedFetchRestoresDirtyStateAndPreservesExistingStashes() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("older local edit\n", to: "existing.txt", in: fixture.repo)
            try git(["stash", "push", "-m", "preexisting"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)
            try write("staged version\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("unstaged version\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            let stagedBefore = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let unstagedBefore = try git(["diff", "--binary"], at: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)
            try git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing-remote.git").path], at: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }

            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == headBefore)
            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == stagedBefore)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == unstagedBefore)
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func divergentHistoryRefusesPullAndRestoresDirtyState() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("remote-only\n", to: "remote.txt", in: fixture.peer)
            try commit("remote side", in: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            try write("local-only\n", to: "local.txt", in: fixture.repo)
            try commit("local side", in: fixture.repo)
            try write("unsaved local edit\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }

            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == headBefore)
            #expect(try read("shared.txt", in: fixture.repo) == "unsaved local edit\n")
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
            #expect(try git(["rev-list", "--count", "HEAD"], at: fixture.repo) == "2")
        }

        @Test func localAheadBranchWithDirtyWorkIsPreservedWhenUpstreamHasNoChanges() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("older local edit\n", to: "existing.txt", in: fixture.repo)
            try git(["stash", "push", "-m", "preexisting"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            try write("local commit\n", to: "ahead.txt", in: fixture.repo)
            try commit("local ahead commit", in: fixture.repo)
            try write("staged version\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("unstaged version\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)
            let stagedBefore = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let unstagedBefore = try git(["diff", "--binary"], at: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            try await client.perform(.stashAndPull, on: repository)

            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == headBefore)
            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == stagedBefore)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == unstagedBefore)
            #expect(try read("shared.txt", in: fixture.repo) == "unstaged version\n")
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func ignoredOnlyFileCollisionWithIncomingTrackedPathIsRefused() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("incoming remote file\n", to: "ignored/cache.txt", in: fixture.peer)
            try git(["add", "-f", "ignored/cache.txt"], at: fixture.peer)
            try git(["-c", "user.name=Branchline Peer", "-c", "user.email=peer@example.test", "commit", "-m", "track ignored path"], at: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            try write("local ignored data\n", to: "ignored/cache.txt", in: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }

            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == headBefore)
            #expect(try read("ignored/cache.txt", in: fixture.repo) == "local ignored data\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func dirtyWorkAndIgnoredFileCollisionWithIncomingTrackedPathArePreserved() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("incoming remote file\n", to: "ignored/cache.txt", in: fixture.peer)
            try git(["add", "-f", "ignored/cache.txt"], at: fixture.peer)
            try git(["-c", "user.name=Branchline Peer", "-c", "user.email=peer@example.test", "commit", "-m", "track ignored path"], at: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            try write("local ignored data\n", to: "ignored/cache.txt", in: fixture.repo)
            try write("staged version\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("unstaged version\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)
            let stagedBefore = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let unstagedBefore = try git(["diff", "--binary"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }

            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == headBefore)
            #expect(try read("ignored/cache.txt", in: fixture.repo) == "local ignored data\n")
            #expect(try read("shared.txt", in: fixture.repo) == "unstaged version\n")
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == stagedBefore)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == unstagedBefore)
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func concurrentStashPullsInLinkedWorktreesRestoreTheirOwnChanges() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("older local edit\n", to: "existing.txt", in: fixture.repo)
            try git(["stash", "push", "-m", "preexisting"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            let side = fixture.root.appendingPathComponent("side-worktree")
            try git(["worktree", "add", "-b", "side", side.path, "origin/main"], at: fixture.repo)
            try git(["push", "-u", "origin", "side"], at: side)
            try write("main remote update\n", to: "main-remote.txt", in: fixture.peer)
            try commit("main remote update", in: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            try write("side remote update\n", to: "side-remote.txt", in: side)
            try commit("side remote update", in: side)
            try git(["push", "origin", "side"], at: side)

            try write("main staged\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("main unstaged\n", to: "shared.txt", in: fixture.repo)
            try write("main untracked\n", to: "main-local.txt", in: fixture.repo)
            try write("side staged\n", to: "shared.txt", in: side)
            try git(["add", "shared.txt"], at: side)
            try write("side unstaged\n", to: "shared.txt", in: side)
            try write("side untracked\n", to: "side-local.txt", in: side)
            let mainStaged = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let mainUnstaged = try git(["diff", "--binary"], at: fixture.repo)
            let sideStaged = try git(["diff", "--cached", "--binary"], at: side)
            let sideUnstaged = try git(["diff", "--binary"], at: side)

            let client = GitClient()
            let mainRepository = try await client.validate(path: fixture.repo.path)
            let sideRepository = try await client.validate(path: side.path)
            async let mainPull: Void = client.perform(.stashAndPull, on: mainRepository)
            async let sidePull: Void = client.perform(.stashAndPull, on: sideRepository)
            _ = try await (mainPull, sidePull)

            #expect(try read("shared.txt", in: fixture.repo) == "main unstaged\n")
            #expect(try read("main-local.txt", in: fixture.repo) == "main untracked\n")
            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == mainStaged)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == mainUnstaged)
            #expect(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("main-remote.txt").path))
            #expect(try read("shared.txt", in: side) == "side unstaged\n")
            #expect(try read("side-local.txt", in: side) == "side untracked\n")
            #expect(try git(["diff", "--cached", "--binary"], at: side) == sideStaged)
            #expect(try git(["diff", "--binary"], at: side) == sideUnstaged)
            #expect(FileManager.default.fileExists(atPath: side.appendingPathComponent("side-remote.txt").path))
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func cancellationDuringFetchRestoresExactLocalStateAndKeepsExistingStashes() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("older local edit\n", to: "existing.txt", in: fixture.repo)
            try git(["stash", "push", "-m", "preexisting"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            try write("staged version\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("unstaged version\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            let stagedBefore = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let unstagedBefore = try git(["diff", "--binary"], at: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            let task = Task {
                try await client.perform(.stashAndPull, on: repository, onProgress: { phase in
                    if phase == .fetching {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            let result = await task.result

            if case .success = result {
                Issue.record("Expected cancellation during fetch")
            }
            #expect(task.isCancelled)
            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) == headBefore)
            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == stagedBefore)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == unstagedBefore)
            #expect(try read("shared.txt", in: fixture.repo) == "unstaged version\n")
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func cancellationDuringRestoreFinishesSafelyWithLocalStateRestored() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("older local edit\n", to: "existing.txt", in: fixture.repo)
            try git(["stash", "push", "-m", "preexisting"], at: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            try write("remote addition\n", to: "remote.txt", in: fixture.peer)
            try commit("remote addition", in: fixture.peer)
            try git(["push", "origin", "main"], at: fixture.peer)
            try write("staged version\n", to: "shared.txt", in: fixture.repo)
            try git(["add", "shared.txt"], at: fixture.repo)
            try write("unstaged version\n", to: "shared.txt", in: fixture.repo)
            try write("untracked local data\n", to: "new-local.txt", in: fixture.repo)
            let stagedBefore = try git(["diff", "--cached", "--binary"], at: fixture.repo)
            let unstagedBefore = try git(["diff", "--binary"], at: fixture.repo)
            let headBefore = try git(["rev-parse", "HEAD"], at: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            let task = Task {
                try await client.perform(.stashAndPull, on: repository, onProgress: { phase in
                    if phase == .restoringLocalChanges {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            let result = await task.result

            if case .failure(let error) = result {
                #expect(error is CancellationError || error is GitClientError)
            }
            #expect(task.isCancelled)
            #expect(try git(["rev-parse", "HEAD"], at: fixture.repo) != headBefore)
            #expect(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("remote.txt").path))
            #expect(try git(["diff", "--cached", "--binary"], at: fixture.repo) == stagedBefore)
            #expect(try git(["diff", "--binary"], at: fixture.repo) == unstagedBefore)
            #expect(try read("shared.txt", in: fixture.repo) == "unstaged version\n")
            #expect(try read("new-local.txt", in: fixture.repo) == "untracked local data\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }

        @Test func missingUpstreamRejectsBeforeStashingDirtyChanges() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repo)
            try git(["config", "user.name", "Branchline Test"], at: repo)
            try git(["config", "user.email", "branchline@example.test"], at: repo)
            try write("base\n", to: "shared.txt", in: repo)
            try commit("base", in: repo)
            try write("local edit\n", to: "shared.txt", in: repo)
            try write("untracked\n", to: "local.txt", in: repo)
            let workingDiffBefore = try git(["diff", "--binary"], at: repo)
            let stashBefore = try stashEntries(in: repo)

            let client = GitClient()
            let repository = try await client.validate(path: repo.path)
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }

            #expect(try git(["diff", "--binary"], at: repo) == workingDiffBefore)
            #expect(try read("local.txt", in: repo) == "untracked\n")
            #expect(try stashEntries(in: repo) == stashBefore)
        }

        @Test func detachedHeadAndGitOperationInProgressRejectBeforeStashing() async throws {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try write("local edit\n", to: "shared.txt", in: fixture.repo)
            try write("untracked\n", to: "local.txt", in: fixture.repo)
            let stashBefore = try stashEntries(in: fixture.repo)

            let client = GitClient()
            let repository = try await client.validate(path: fixture.repo.path)
            try git(["checkout", "--detach", "HEAD"], at: fixture.repo)
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }
            #expect(try read("shared.txt", in: fixture.repo) == "local edit\n")
            #expect(try read("local.txt", in: fixture.repo) == "untracked\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)

            try git(["checkout", "main"], at: fixture.repo)
            let head = try git(["rev-parse", "HEAD"], at: fixture.repo)
            try Data((head + "\n").utf8).write(to: fixture.repo.appendingPathComponent(".git/MERGE_HEAD"))
            await #expect(throws: GitClientError.self) { try await client.perform(.stashAndPull, on: repository) }
            #expect(try read("shared.txt", in: fixture.repo) == "local edit\n")
            #expect(try read("local.txt", in: fixture.repo) == "untracked\n")
            #expect(try stashEntries(in: fixture.repo) == stashBefore)
        }
    }
}
