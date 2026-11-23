import Foundation
import Testing
@testable import Branchline

@MainActor
struct RepositoryOpenerTests {
    @Test func claudeFolderLinksPreserveSpecialCharactersWithoutAddingParameters() throws {
        let path = "/tmp/worktree + '&folder=other? #/مشروع\nnext"
        let url = try #require(RepositoryOpener.claudeCodeURL(for: path))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "claude")
        #expect(components.host == "code")
        #expect(components.path == "/new")
        #expect(components.queryItems == [URLQueryItem(name: "folder", value: path)])
        #expect(!url.absoluteString.contains("+"))
        #expect(components.fragment == nil)
    }
}
