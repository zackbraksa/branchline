import Foundation
import Testing
@testable import BranchlineCore

private struct SyncFixture {
    let root: URL
    let seed: URL
    let checkout: URL
    let remote: URL
    var repository: Repository { Repository(path: checkout.path) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlineDependable-\(UUID())")
        seed = root.appendingPathComponent("seed")
        checkout = root.appendingPathComponent("checkout")
        remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try Self.git(["init", "-b", "main"], at: seed)
        try Data("base\n".utf8).write(to: seed.appendingPathComponent("file.txt"))
        try Self.git(["add", "."], at: seed)
        try Self.git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-m", "base"], at: seed)
        try Self.git(["clone", "--bare", seed.path, remote.path], at: root)
        try Self.git(["remote", "add", "origin", remote.path], at: seed)
        try Self.git(["clone", remote.path, checkout.path], at: root)
        try Self.git(["config", "user.name", "Test"], at: checkout)
        try Self.git(["config", "user.email", "test@example.test"], at: checkout)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    @discardableResult static func git(_ args: [String], at path: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = path
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SyncFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    @discardableResult func git(_ args: [String], at path: URL? = nil) throws -> String { try Self.git(args, at: path ?? checkout) }
    func advanceRemote() throws {
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "remote change"], at: seed)
        try git(["push", "origin", "main"], at: seed)
    }
    func localCommit() throws { try git(["commit", "--allow-empty", "-m", "local change"]) }
}

extension GitRepositoryTests {
    struct DependableSyncTests {
        @Test func automaticPullUsesFreshExplicitUpstreamDespiteCustomRefspecAndSkipFetchAll() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.git(["config", "remote.origin.skipFetchAll", "true"])
            try fixture.git(["config", "remote.origin.fetch", "+refs/heads/other:refs/remotes/origin/other"])
            try fixture.git(["branch", "other"], at: fixture.seed)
            try fixture.git(["push", "origin", "other"], at: fixture.seed)
            try fixture.advanceRemote()
            let result = await GitClient().synchronize([fixture.repository], mode: .background(autoPull: true), timeout: 3)
            #expect(result.first?.outcome == .updated)
            #expect(result.first?.fetched == true)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == fixture.git(["rev-parse", "main"], at: fixture.remote))
            #expect(try fixture.git(["stash", "list"]).isEmpty)
        }

        @Test(arguments: ["staged", "unstaged", "untracked", "feature", "unknownDefault", "detached", "noUpstream", "busy", "indexLock", "diverged", "localUpstream"])
        func automaticPullSkipsUnsafeCheckouts(scenario: String) async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.advanceRemote()
            let expected: SyncSkipReason
            switch scenario {
            case "staged":
                try Data("changed\n".utf8).write(to: fixture.checkout.appendingPathComponent("file.txt"))
                try fixture.git(["add", "file.txt"]); expected = .localChanges
            case "unstaged":
                try Data("changed\n".utf8).write(to: fixture.checkout.appendingPathComponent("file.txt")); expected = .localChanges
            case "untracked":
                try Data("new\n".utf8).write(to: fixture.checkout.appendingPathComponent("new.txt")); expected = .localChanges
            case "feature":
                try fixture.git(["switch", "-c", "feature"])
                try fixture.git(["branch", "--set-upstream-to=origin/main"]); expected = .featureBranch
            case "unknownDefault":
                try fixture.git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"]); expected = .unknownDefaultBranch
            case "detached": try fixture.git(["switch", "--detach"]); expected = .detached
            case "noUpstream": try fixture.git(["branch", "--unset-upstream"]); expected = .missingUpstream
            case "busy":
                try Data("busy".utf8).write(to: fixture.checkout.appendingPathComponent(".git/MERGE_HEAD")); expected = .busy
            case "indexLock":
                try Data("busy".utf8).write(to: fixture.checkout.appendingPathComponent(".git/index.lock")); expected = .busy
            case "diverged": try fixture.localCommit(); expected = .diverged
            default:
                try fixture.git(["branch", "local"])
                try fixture.git(["branch", "--set-upstream-to=local"]); expected = .localUpstream
            }
            let head = try fixture.git(["rev-parse", "HEAD"])
            let result = await GitClient().synchronize([fixture.repository], mode: .background(autoPull: true), timeout: 3)
            #expect(result.first?.outcome == .skipped)
            #expect(result.first?.reason == expected)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
            #expect(try fixture.git(["stash", "list"]).isEmpty)
        }

        @Test func pushEligiblePublishesOnlyCleanOutgoingCommits() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.localCommit()
            let client = GitClient()
            try Data("unfinished\n".utf8).write(to: fixture.checkout.appendingPathComponent("new.txt"))
            let dirty = await client.synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(dirty.first?.reason == .localChanges)
            #expect(try fixture.git(["rev-parse", "HEAD"]) != fixture.git(["rev-parse", "main"], at: fixture.remote))
            try FileManager.default.removeItem(at: fixture.checkout.appendingPathComponent("new.txt"))
            let clean = await client.synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(clean.first?.outcome == .updated)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == fixture.git(["rev-parse", "main"], at: fixture.remote))
        }

        @Test func failedFreshnessPreventsAutomaticPullAndPush() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.advanceRemote()
            try fixture.git(["fetch", "origin"])
            try fixture.git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").path])
            let head = try fixture.git(["rev-parse", "HEAD"])
            for mode in [SyncMode.background(autoPull: true), .pushEligible] {
                let result = await GitClient().synchronize([fixture.repository], mode: mode, timeout: 3)
                #expect(result.first?.outcome == .failed)
                #expect(result.first?.reason == .remoteCheckFailed)
                #expect(result.first?.fetched == false)
            }
            #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
        }

        @Test func ambiguousTargetsRemainSkippedWhenRetryTargetsOnlyOneCheckout() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.localCommit()
            let sibling = fixture.root.appendingPathComponent("sibling")
            try fixture.git(["worktree", "add", "-b", "sibling", sibling.path])
            try fixture.git(["branch", "--set-upstream-to=origin/main", "sibling"])
            let context = [fixture.repository, Repository(path: sibling.path)]
            let result = await GitClient().synchronize([fixture.repository], mode: .pushEligible, timeout: 3, pushContext: context)
            #expect(result.first?.reason == .ambiguousPushTarget)
            #expect(try fixture.git(["rev-parse", "HEAD"]) != fixture.git(["rev-parse", "main"], at: fixture.remote))
        }

        @Test(arguments: ["HEAD", "branch", "upstream"])
        func checkoutChangesDuringFetchPreventWrites(change: String) async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.advanceRemote()
            try fixture.git(["branch", "other"])
            let helper = fixture.root.appendingPathComponent("upload-pack.sh")
            let mutation: String
            switch change {
            case "HEAD": mutation = "/usr/bin/git -C '\(fixture.checkout.path)' commit --allow-empty -m external"
            case "branch": mutation = "/usr/bin/git -C '\(fixture.checkout.path)' symbolic-ref HEAD refs/heads/other"
            default: mutation = "/usr/bin/git -C '\(fixture.checkout.path)' config branch.main.merge refs/heads/other"
            }
            try Data("#!/bin/sh\n\(mutation) >/dev/null\nexec /usr/bin/git-upload-pack \"$@\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "remote.origin.uploadpack", helper.path])
            let remoteHead = try fixture.git(["rev-parse", "main"], at: fixture.remote)
            let result = await GitClient().synchronize([fixture.repository], mode: .background(autoPull: true), timeout: 3)
            #expect(result.first?.reason == .checkoutChanged)
            #expect(try fixture.git(["rev-parse", "HEAD"]) != remoteHead)
        }

        @Test func dirtySubmodulesCannotBeHiddenByUserConfiguration() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", fixture.remote.path, "module"])
            try fixture.git(["commit", "-m", "add module"])
            try fixture.git(["config", "submodule.module.ignore", "all"])
            try fixture.git(["config", "diff.ignoreSubmodules", "all"])
            try Data("unfinished\n".utf8).write(to: fixture.checkout.appendingPathComponent("module/file.txt"))
            let result = await GitClient().synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(result.first?.reason == .localChanges)
        }
        @Test func hiddenUntrackedFilesAreStillDirtyForEligiblePush() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.localCommit()
            try fixture.git(["config", "status.showUntrackedFiles", "no"])
            try Data("unfinished\n".utf8).write(to: fixture.checkout.appendingPathComponent("hidden.txt"))
            let result = await GitClient().synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(result.first?.reason == .localChanges)
            #expect(try fixture.git(["rev-parse", "HEAD"]) != fixture.git(["rev-parse", "main"], at: fixture.remote))
        }

        @Test func multiplePushDestinationsAreNotPublished() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.localCommit()
            let secondary = fixture.root.appendingPathComponent("secondary.git")
            try fixture.git(["clone", "--bare", fixture.remote.path, secondary.path], at: fixture.root)
            try fixture.git(["config", "--add", "remote.origin.pushurl", fixture.remote.path])
            try fixture.git(["config", "--add", "remote.origin.pushurl", secondary.path])
            let before = try fixture.git(["rev-parse", "main"], at: fixture.remote)
            let result = await GitClient().synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(result.first?.outcome == .skipped)
            #expect(result.first?.reason == .remoteCheckFailed)
            #expect(try fixture.git(["rev-parse", "main"], at: fixture.remote) == before)
            #expect(try fixture.git(["rev-parse", "main"], at: secondary) == before)
        }

        @Test func worktreeSpecificRemoteConfigurationFailsFreshnessClosed() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.advanceRemote()
            let sibling = fixture.root.appendingPathComponent("sibling")
            try fixture.git(["worktree", "add", "-b", "sibling", sibling.path])
            try fixture.git(["branch", "--set-upstream-to=origin/main", "sibling"])
            try fixture.git(["config", "extensions.worktreeConfig", "true"])
            try fixture.git(["config", "--local", "--unset-all", "remote.origin.url"])
            try fixture.git(["config", "--worktree", "remote.origin.url", fixture.remote.path])
            let differentRemote = fixture.root.appendingPathComponent("different.git").path
            try fixture.git(["config", "--worktree", "remote.origin.url", differentRemote], at: sibling)
            #expect(try fixture.git(["remote", "get-url", "origin"]) == fixture.remote.path)
            #expect(try fixture.git(["remote", "get-url", "origin"], at: sibling) == differentRemote)
            let before = try fixture.git(["rev-parse", "HEAD"])
            let result = await GitClient().synchronize([fixture.repository, Repository(path: sibling.path)], mode: .background(autoPull: true), timeout: 3)
            #expect(result.allSatisfy { $0.outcome == .failed && $0.reason == .remoteCheckFailed && !$0.fetched })
            #expect(try fixture.git(["rev-parse", "HEAD"]) == before)
        }

        @Test func groupedFetchDeduplicatesSharedUpstreamAndHonorsTagPolicy() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            let sibling = fixture.root.appendingPathComponent("sibling")
            try fixture.git(["worktree", "add", "-b", "sibling", sibling.path])
            try fixture.git(["branch", "--set-upstream-to=origin/main", "sibling"])
            let helper = fixture.root.appendingPathComponent("upload-pack.sh")
            let count = fixture.root.appendingPathComponent("fetch-count")
            try Data("#!/bin/sh\necho fetched >> '\(count.path)'\nexec /usr/bin/git-upload-pack \"$@\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "remote.origin.uploadpack", helper.path])
            try fixture.git(["config", "remote.origin.tagOpt", "--no-tags"])
            try fixture.git(["tag", "new-tag"], at: fixture.seed)
            try fixture.git(["push", "origin", "refs/tags/new-tag"], at: fixture.seed)
            let result = await GitClient().synchronize([fixture.repository, Repository(path: sibling.path)], mode: .background(autoPull: false), timeout: 3)
            #expect(result.count == 2 && result.allSatisfy(\.fetched))
            #expect(try String(contentsOf: count, encoding: .utf8).split(whereSeparator: \.isNewline).count == 1)
            #expect(try fixture.git(["tag", "--list"]).isEmpty)
        }

        @Test func cancelledWaiterDoesNotWaitForSharedWorktreeNetworkLock() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            let helper = fixture.root.appendingPathComponent("upload-pack.sh")
            let marker = fixture.root.appendingPathComponent("started")
            try Data("#!/bin/sh\necho started > '\(marker.path)'\n/bin/sleep 120\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "remote.origin.uploadpack", helper.path])
            let client = GitClient()
            let first = Task { await client.synchronize([fixture.repository], mode: .background(autoPull: false), timeout: 3) }
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: marker.path))
            let second = Task { await client.synchronize([fixture.repository], mode: .background(autoPull: true), timeout: 3) }
            try await Task.sleep(for: .milliseconds(100))
            let start = ContinuousClock.now
            second.cancel()
            let result = await second.value
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(result.first?.outcome == .cancelled)
            first.cancel()
            #expect(await first.value.first?.outcome == .cancelled)
        }

        @Test func pushEligiblePreservesReceivePackAndSkipsUnsupportedProxy() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.localCommit()
            let helper = fixture.root.appendingPathComponent("receive-pack.sh")
            let marker = fixture.root.appendingPathComponent("received")
            try Data("#!/bin/sh\necho received > '\(marker.path)'\nexec /usr/bin/git-receive-pack \"$@\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            try fixture.git(["config", "remote.origin.receivepack", helper.path])
            try fixture.git(["config", "remote.origin.proxy", "http://127.0.0.1:1"])
            let client = GitClient()
            let blocked = await client.synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(blocked.first?.outcome == .failed)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            try fixture.git(["config", "--unset", "remote.origin.proxy"])
            let result = await client.synchronize([fixture.repository], mode: .pushEligible, timeout: 3)
            #expect(result.first?.outcome == .updated)
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }

        @Test func globalPushPreflightSkipsIndependentClonesSharingADestination() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            try fixture.localCommit()
            let other = fixture.root.appendingPathComponent("independent")
            try fixture.git(["clone", fixture.remote.path, other.path], at: fixture.root)
            try fixture.git(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "other outgoing"], at: other)
            let client = GitClient()
            let otherRepository = Repository(path: other.path)
            let destinations = await client.pushDestinations([fixture.repository, otherRepository])
            #expect(destinations.count == 2 && Set(destinations.values).count == 1)
            let before = try fixture.git(["rev-parse", "main"], at: fixture.remote)
            let first = await client.synchronize([fixture.repository], mode: .pushEligible, timeout: 3, pushDestinations: destinations)
            let second = await client.synchronize([otherRepository], mode: .pushEligible, timeout: 3, pushDestinations: destinations)
            #expect(first.first?.reason == .ambiguousPushTarget)
            #expect(second.first?.reason == .ambiguousPushTarget)
            #expect(try fixture.git(["rev-parse", "main"], at: fixture.remote) == before)
            let stale = await client.synchronize([fixture.repository], mode: .pushEligible, timeout: 3, pushDestinations: [:])
            #expect(stale.first?.reason == .checkoutChanged)
        }

        @Test func bareRelativeRemotePathsAreResolvedPerCheckout() async throws {
            let fixture = try SyncFixture(); defer { fixture.cleanUp() }
            let sibling = fixture.root.appendingPathComponent("sibling")
            try fixture.git(["worktree", "add", "-b", "sibling", sibling.path])
            try fixture.git(["branch", "--set-upstream-to=origin/main", "sibling"])
            try fixture.git(["clone", "--bare", fixture.remote.path, "upstream.git"])
            try fixture.git(["clone", "--bare", fixture.remote.path, "upstream.git"], at: sibling)
            try fixture.git(["remote", "set-url", "origin", "upstream.git"])
            let client = GitClient(), other = Repository(path: sibling.path)
            let destinations = await client.pushDestinations([fixture.repository, other])
            #expect(destinations.count == 2 && Set(destinations.values).count == 2)
            let result = await client.synchronize([fixture.repository, other], mode: .background(autoPull: true), timeout: 3)
            #expect(result.allSatisfy { $0.outcome == .failed && $0.reason == .remoteCheckFailed && !$0.fetched })
        }

    }
}
