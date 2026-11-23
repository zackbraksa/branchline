import Foundation
import Testing
@testable import BranchlineCore

extension GitRepositoryTests {
    struct GitClientTests {
        @Test(.timeLimit(.minutes(1))) func concurrentStatusReadsFinishWithoutBlockingOutputCollection() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], at: root)
            let repository = Repository(path: root.path)
            let client = GitClient()
            try await withThrowingTaskGroup(of: RepositoryStatus.self) { group in
                for _ in 0..<96 {
                    group.addTask { try await client.status(repository) }
                }
                var completed = 0
                for try await status in group {
                    #expect(status.branch == "main")
                    completed += 1
                }
                #expect(completed == 96)
            }
        }

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        @discardableResult
        private func git(_ args: [String], at directory: URL, input: Data? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let output = Pipe(), error = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try? stdin.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "GitClientTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(String(decoding: err, as: UTF8.self))"])
            }
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func write(_ contents: String, to path: String, in directory: URL) throws {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        private func commit(_ message: String, in directory: URL) throws {
            try git(["add", "-A"], at: directory)
            try git(["-c", "user.name=Branchline Test", "-c", "user.email=branchline@example.test", "commit", "-m", message], at: directory)
        }

        @Test func validatesReadsHistoryTagsFilesAndStatus() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("same bytes\n", to: "cafe\nname.txt", in: repoPath)
            try commit("root commit\nfull body", in: repoPath)
            try git(["tag", "-a", "release-v1", "-m", "release"], at: repoPath)
            try git(["switch", "-c", "topic"], at: repoPath)
            try FileManager.default.removeItem(at: repoPath.appendingPathComponent("cafe\nname.txt"))
            try write("same bytes\n", to: "renamed-雪.txt", in: repoPath)
            try commit("rename file" , in: repoPath)
            try git(["switch", "main"], at: repoPath)
            try write("main\n", to: "main.txt", in: repoPath)
            try commit("main change", in: repoPath)
            try git(["merge", "--no-ff", "topic", "-m", "merge topic"], at: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            #expect(repository.path == repoPath.resolvingSymlinksInPath().path)
            let page = try await client.history(repository, limit: 2, branch: nil, includeRemotes: false)
            #expect(page.commits.count == 2)
            #expect(page.hasMore)
            #expect(page.commits.first?.subject == "merge topic")
            #expect(page.refs.contains(where: { $0.fullName == "refs/tags/release-v1" && $0.target.count >= 40 }))
            let complete = try await client.history(repository, limit: 30, branch: "refs/heads/topic", includeRemotes: false)
            #expect(complete.commits.count == 2)
            #expect(complete.commits.first?.subject == "rename file")
            #expect(complete.commits.last?.message.contains("full body") == true)
            let files = try await client.files(repository, commit: complete.commits[0])
            #expect(files.contains(where: { $0.oldPath == "cafe\nname.txt" && $0.path == "renamed-雪.txt" && $0.status.hasPrefix("R") }))
            let rootFiles = try await client.files(repository, commit: complete.commits[1])
            #expect(rootFiles.contains(where: { $0.path == "cafe\nname.txt" && $0.status == "A" }))
            let status = try await client.status(repository)
            #expect(status.branch == "main")
            #expect(status.changedFiles == 0)
        }

        @Test func handlesUnbornRepositoriesAndRejectsUnsafeOperations() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init"], at: repoPath)
            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let page = try await client.history(repository, limit: 10, branch: nil, includeRemotes: true)
            #expect(page.commits.isEmpty)
            #expect(!page.hasMore)
            await #expect(throws: GitClientError.self) { try await client.perform(.pull, on: repository) }
        }

        @Test func resolvesCachedRemoteDefaultBranchAndMarksOnlyBranchRefs() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "develop"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("base\n", to: "base.txt", in: repoPath)
            try commit("base", in: repoPath)
            let oid = try git(["rev-parse", "HEAD"], at: repoPath)
            try git(["branch", "feature/topic"], at: repoPath)
            try git(["branch", "release/HEAD"], at: repoPath)
            try git(["update-ref", "refs/remotes/origin/release/HEAD", oid], at: repoPath)
            try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/release/HEAD"], at: repoPath)
            try git(["tag", "-a", "release", "-m", "release"], at: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let status = try await client.status(repository)
            #expect(status.branch == "develop")
            #expect(status.defaultBranch == "release/HEAD")
            let page = try await client.history(repository, limit: 10, includeRemotes: true)
            #expect(page.refs.contains(where: { $0.fullName == "refs/heads/release/HEAD" && $0.isDefaultBranch }))
            #expect(page.refs.contains(where: { $0.fullName == "refs/remotes/origin/release/HEAD" && $0.isDefaultBranch }))
            #expect(!page.refs.contains(where: { $0.fullName == "refs/heads/develop" && $0.isDefaultBranch }))
            #expect(!page.refs.contains(where: { $0.fullName == "refs/tags/release" && $0.isDefaultBranch }))
            #expect(!page.refs.contains(where: { $0.fullName == "HEAD" && $0.isDefaultBranch }))
        }

        @Test func missingOrAmbiguousRemoteHeadDoesNotGuessDefaultBranch() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("base\n", to: "base.txt", in: repoPath)
            try commit("base", in: repoPath)
            let oid = try git(["rev-parse", "HEAD"], at: repoPath)
            try git(["update-ref", "refs/remotes/alpha/main", oid], at: repoPath)
            try git(["update-ref", "refs/remotes/beta/trunk", oid], at: repoPath)
            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            #expect(try await client.status(repository).defaultBranch == nil)
            try git(["symbolic-ref", "refs/remotes/alpha/HEAD", "refs/remotes/alpha/main"], at: repoPath)
            try git(["symbolic-ref", "refs/remotes/beta/HEAD", "refs/remotes/beta/trunk"], at: repoPath)

            #expect(try await client.status(repository).defaultBranch == nil)
            let page = try await client.history(repository, limit: 10, includeRemotes: true)
            #expect(!page.refs.contains(where: { $0.isDefaultBranch }))
        }

        @Test func usesCurrentUpstreamRemoteAndSupportsDetachedHead() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "topic/feature"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("base\n", to: "base.txt", in: repoPath)
            try commit("base", in: repoPath)
            let oid = try git(["rev-parse", "HEAD"], at: repoPath)
            try git(["update-ref", "refs/tags/topic/feature", oid], at: repoPath)
            try git(["branch", "mainline", oid], at: repoPath)
            try git(["update-ref", "refs/remotes/team/mainline", oid], at: repoPath)
            try git(["update-ref", "refs/remotes/backup/trunk", oid], at: repoPath)
            try git(["symbolic-ref", "refs/remotes/team/HEAD", "refs/remotes/team/mainline"], at: repoPath)
            try git(["symbolic-ref", "refs/remotes/backup/HEAD", "refs/remotes/backup/trunk"], at: repoPath)
            try git(["config", "branch.topic/feature.remote", "team"], at: repoPath)
            try git(["config", "branch.topic/feature.merge", "refs/heads/mainline"], at: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let status = try await client.status(repository)
            #expect(status.defaultBranch == "mainline")
            let page = try await client.history(repository, limit: 10, includeRemotes: true)
            #expect(page.refs.contains(where: { $0.fullName == "refs/heads/mainline" && $0.isDefaultBranch }))
            #expect(page.refs.contains(where: { $0.fullName == "refs/remotes/team/mainline" && $0.isDefaultBranch }))
            #expect(!page.refs.contains(where: { $0.fullName == "refs/remotes/backup/trunk" && $0.isDefaultBranch }))
            try git(["checkout", "--detach", "HEAD"], at: repoPath)
            let detached = try await client.status(repository)
            #expect(detached.branch == nil)
            #expect(detached.defaultBranch == nil)
        }

        @Test func performsExplicitPushAndFastForwardPullAgainstLocalBareRemote() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bare = root.appendingPathComponent("remote.git")
            let repoPath = root.appendingPathComponent("repo")
            let clonePath = root.appendingPathComponent("peer")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "--bare", bare.path], at: root)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("base\n", to: "file.txt", in: repoPath)
            try commit("base", in: repoPath)
            try git(["remote", "add", "origin", bare.path], at: repoPath)
            try git(["push", "-u", "origin", "main"], at: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            try write("local\n", to: "local.txt", in: repoPath)
            try commit("local", in: repoPath)
            try await client.perform(.push, on: repository)

            try git(["clone", "--branch", "main", bare.path, clonePath.path], at: root)
            try git(["config", "user.name", "Branchline Peer"], at: clonePath)
            try git(["config", "user.email", "peer@example.test"], at: clonePath)
            try write("remote\n", to: "remote.txt", in: clonePath)
            try commit("remote", in: clonePath)
            try git(["push", "origin", "main"], at: clonePath)
            try await client.perform(.fetch, on: repository)
            let beforePull = try await client.status(repository)
            #expect(beforePull.behind == 1)
            try write("dirty\n", to: "local.txt", in: repoPath)
            await #expect(throws: GitClientError.self) { try await client.perform(.pull, on: repository) }
            try git(["checkout", "--", "local.txt"], at: repoPath)
            try await client.perform(.pull, on: repository)
            let afterPull = try await client.status(repository)
            #expect(afterPull.behind == 0)
            #expect(FileManager.default.fileExists(atPath: repoPath.appendingPathComponent("remote.txt").path))
        }

        @Test func scansOnlyImmediateChildRepositories() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = root.appendingPathComponent("project")
            let nested = root.appendingPathComponent("node_modules/dependency")
            let invalid = root.appendingPathComponent("broken")
            let deep = root.appendingPathComponent("other-projects/nested-repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: invalid.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try git(["init"], at: repo)
            try git(["init"], at: nested)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try git(["init"], at: deep)
            try write("base", to: "file.txt", in: repo)
            try commit("initial", in: repo)
            let nestedWorktree = root.appendingPathComponent("worktrees/nested-worktree")
            try git(["worktree", "add", "--detach", nestedWorktree.path], at: repo)
            let found = try await RepositoryDiscovery.scan(root)
            #expect(found.map(\.path) == [repo.resolvingSymlinksInPath().path])
        }

        @Test func refusesDivergedPullWithoutChangingHeadOrWorkingTree() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bare = root.appendingPathComponent("remote.git")
            let repoPath = root.appendingPathComponent("repo")
            let peer = root.appendingPathComponent("peer")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "--bare", bare.path], at: root)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("base\n", to: "base.txt", in: repoPath)
            try commit("base", in: repoPath)
            try git(["remote", "add", "origin", bare.path], at: repoPath)
            try git(["push", "-u", "origin", "main"], at: repoPath)

            try git(["clone", "--branch", "main", bare.path, peer.path], at: root)
            try git(["config", "user.name", "Branchline Peer"], at: peer)
            try git(["config", "user.email", "peer@example.test"], at: peer)
            try write("remote\n", to: "remote.txt", in: peer)
            try commit("remote side", in: peer)
            try git(["push", "origin", "main"], at: peer)
            try write("local\n", to: "local.txt", in: repoPath)
            try commit("local side", in: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let headBefore = try git(["rev-parse", "HEAD"], at: repoPath)
            let localBefore = try Data(contentsOf: repoPath.appendingPathComponent("local.txt"))
            await #expect(throws: GitClientError.self) { try await client.perform(.pull, on: repository) }
            #expect(try git(["rev-parse", "HEAD"], at: repoPath) == headBefore)
            #expect(try Data(contentsOf: repoPath.appendingPathComponent("local.txt")) == localBefore)
            #expect(!FileManager.default.fileExists(atPath: repoPath.appendingPathComponent("remote.txt").path))
        }

        @Test func refusesDetachedAndMissingUpstreamOperations() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("commit\n", to: "file.txt", in: repoPath)
            try commit("one commit", in: repoPath)
            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)

            await #expect(throws: GitClientError.self) { try await client.perform(.pull, on: repository) }
            await #expect(throws: GitClientError.self) { try await client.perform(.push, on: repository) }
            try git(["checkout", "--detach", "HEAD"], at: repoPath)
            let detached = try await client.status(repository)
            #expect(detached.branch == nil)
            await #expect(throws: GitClientError.self) { try await client.perform(.pull, on: repository) }
            await #expect(throws: GitClientError.self) { try await client.perform(.push, on: repository) }
        }

        @Test func mergeHeadMarkerBlocksPull() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bare = root.appendingPathComponent("remote.git")
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "--bare", bare.path], at: root)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("base\n", to: "file.txt", in: repoPath)
            try commit("base", in: repoPath)
            try git(["remote", "add", "origin", bare.path], at: repoPath)
            try git(["push", "-u", "origin", "main"], at: repoPath)
            let head = try git(["rev-parse", "HEAD"], at: repoPath)
            try Data((head + "\n").utf8).write(to: repoPath.appendingPathComponent(".git/MERGE_HEAD"))

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let status = try await client.status(repository)
            #expect(status.operationInProgress)
            await #expect(throws: GitClientError.self) { try await client.perform(.pull, on: repository) }
            #expect(try git(["rev-parse", "HEAD"], at: repoPath) == head)
        }

        @Test func searchMatchesLiteralQueryAuthorAndHash() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Literal [author]"], at: repoPath)
            try git(["config", "user.email", "literal@example.test"], at: repoPath)
            try write("text\n", to: "file.txt", in: repoPath)
            try git(["add", "-A"], at: repoPath)
            try git(["commit", "-m", "subject contains [literal] marker"], at: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let fullHistory = try await client.history(repository, limit: 5)
            let commit = try #require(fullHistory.commits.first)
            #expect(try await client.search(repository, query: "[literal]").map(\.id) == [commit.id])
            #expect(try await client.search(repository, query: "literal [author]").map(\.id) == [commit.id])
            #expect(try await client.search(repository, query: String(commit.id.prefix(8))).map(\.id) == [commit.id])
        }

        @Test func statusCountsRenameAndNewlineUntrackedPathOnceEach() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repoPath = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repoPath)
            try git(["config", "user.name", "Branchline Test"], at: repoPath)
            try git(["config", "user.email", "branchline@example.test"], at: repoPath)
            try write("unchanged content\n", to: "before.txt", in: repoPath)
            try commit("base", in: repoPath)
            try git(["mv", "before.txt", "after.txt"], at: repoPath)
            try write("untracked\n", to: "new\nfile.txt", in: repoPath)

            let client = GitClient()
            let repository = try await client.validate(path: repoPath.path)
            let status = try await client.status(repository)
            #expect(status.changedFiles == 2)
        }
    }
}
