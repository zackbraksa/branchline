import Foundation
import Testing
@testable import BranchlineCore

extension GitRepositoryTests {
    struct PendingChangesTests {
        @discardableResult
        private func git(_ arguments: [String], at directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out; process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "Git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]) }
            return String(decoding: data, as: UTF8.self)
        }

        private func fixture() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BranchlinePendingTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: root)
            try git(["config", "user.name", "Test"], at: root)
            try git(["config", "user.email", "test@example.test"], at: root)
            try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try Data("other\n".utf8).write(to: root.appendingPathComponent("other.txt"))
            try git(["add", "."], at: root)
            try git(["commit", "-m", "base"], at: root)
            return root
        }

        @Test func selectedDiscardPreservesOtherFilesAndBacksUpBothVersions() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = GitClient(), repo = Repository(path: root.path)
            try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try git(["add", "tracked.txt"], at: root)
            try Data("working\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try Data("keep\n".utf8).write(to: root.appendingPathComponent("other.txt"))
            try Data("new\n".utf8).write(to: root.appendingPathComponent(":(glob)*.txt"))
            let snapshot = try await client.pendingChanges(repo)
            #expect(snapshot.files.count == 3)
            #expect(snapshot.files.first { $0.path == "tracked.txt" }?.summary == "Modified · Staged + unstaged")
            let backup = try await client.discardChanges(repo, snapshot: snapshot, paths: ["tracked.txt", ":(glob)*.txt"])
            defer { try? FileManager.default.removeItem(at: backup) }
            #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "base\n")
            #expect(try String(contentsOf: root.appendingPathComponent("other.txt"), encoding: .utf8) == "keep\n")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(":(glob)*.txt").path))
            #expect(try String(contentsOf: backup.appendingPathComponent("Files/tracked.txt"), encoding: .utf8) == "working\n")
            #expect(try String(contentsOf: backup.appendingPathComponent("Staged changes.patch"), encoding: .utf8).contains("+staged"))
            #expect(try await client.pendingChanges(repo).files.map(\.path) == ["other.txt"])
        }

        @Test func stagedRenameAndAdditionReturnToHead() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = GitClient(), repo = Repository(path: root.path)
            try git(["mv", "tracked.txt", "renamed file\n.txt"], at: root)
            try Data("added\n".utf8).write(to: root.appendingPathComponent("added.txt"))
            try git(["add", "added.txt"], at: root)
            let snapshot = try await client.pendingChanges(repo)
            #expect(snapshot.files.first { $0.path == "renamed file\n.txt" }?.oldPath == "tracked.txt")
            let backup = try await client.discardChanges(repo, snapshot: snapshot, paths: Set(snapshot.files.map(\.path)))
            defer { try? FileManager.default.removeItem(at: backup) }
            #expect(try await client.status(repo).changedFiles == 0)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tracked.txt").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("added.txt").path))
        }

        @Test func staleContentRefusesDiscardWithoutTouchingAnything() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = GitClient(), repo = Repository(path: root.path)
            try Data("first\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            let snapshot = try await client.pendingChanges(repo)
            try Data("later\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            await #expect(throws: (any Error).self) {
                try await client.discardChanges(repo, snapshot: snapshot, paths: ["tracked.txt"])
            }
            #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "later\n")
        }

        @Test func nestedRepositoriesCannotBeDiscarded() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try git(["init"], at: nested)
            let snapshot = try await GitClient().pendingChanges(Repository(path: root.path))
            #expect(snapshot.files.first?.unavailableReason != nil)
        }
        @Test func renameOverlapRequiresSelectingBothAndRestoresSource() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = GitClient(), repo = Repository(path: root.path)
            try git(["mv", "tracked.txt", "renamed.txt"], at: root)
            try Data("new source\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            let snapshot = try await client.pendingChanges(repo)
            await #expect(throws: (any Error).self) {
                try await client.discardChanges(repo, snapshot: snapshot, paths: ["renamed.txt"])
            }
            #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "new source\n")
            let backup = try await client.discardChanges(repo, snapshot: snapshot, paths: ["renamed.txt", "tracked.txt"])
            defer { try? FileManager.default.removeItem(at: backup) }
            #expect(try await client.status(repo).changedFiles == 0)
            #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "base\n")
        }

        @Test func deletedAndSymlinkFilesAreRestoredWithoutTouchingTarget() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "tracked.txt")
            try git(["add", "link"], at: root)
            try git(["commit", "-m", "link"], at: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "other.txt")
            try FileManager.default.removeItem(at: root.appendingPathComponent("tracked.txt"))
            let client = GitClient(), repo = Repository(path: root.path)
            let snapshot = try await client.pendingChanges(repo)
            let backup = try await client.discardChanges(repo, snapshot: snapshot, paths: Set(snapshot.files.map(\.path)))
            defer { try? FileManager.default.removeItem(at: backup) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path) == "tracked.txt")
            #expect(try String(contentsOf: root.appendingPathComponent("other.txt"), encoding: .utf8) == "other\n")
            #expect(try await client.status(repo).changedFiles == 0)
        }

        @Test func failedRestoreRetainsRecoverableBackup() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("tracked.txt filter=reject\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
            try git(["add", ".gitattributes"], at: root)
            try git(["commit", "-m", "attributes"], at: root)
            try git(["config", "filter.reject.clean", "cat"], at: root)
            try git(["config", "filter.reject.smudge", "false"], at: root)
            try git(["config", "filter.reject.required", "true"], at: root)
            try Data("precious work\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            let client = GitClient(), repo = Repository(path: root.path)
            let snapshot = try await client.pendingChanges(repo)
            do {
                _ = try await client.discardChanges(repo, snapshot: snapshot, paths: ["tracked.txt"])
                Issue.record("Expected the checkout filter to reject restoration")
            } catch {
                let message = error.localizedDescription
                #expect(message.contains("backup, including staged changes, is in Trash:"))
                if let range = message.range(of: "is in Trash: ") {
                    let backup = URL(fileURLWithPath: String(message[range.upperBound...]))
                    defer { try? FileManager.default.removeItem(at: backup) }
                    #expect(try String(contentsOf: backup.appendingPathComponent("Files/tracked.txt"), encoding: .utf8) == "precious work\n")
                }
            }
        }

    }
}
