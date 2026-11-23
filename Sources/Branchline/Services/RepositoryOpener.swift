import AppKit
import BranchlineCore

@MainActor
enum RepositoryOpener {
    enum Destination { case claudeCode, terminal }

    static func claudeCodeURL(for path: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let folder = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "claude://code/new?folder=\(folder)")
    }

    static func open(_ repository: Repository, in destination: Destination) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OpeningError.message("This checkout's folder is no longer available.")
        }
        let workspace = NSWorkspace.shared
        let url: URL
        let application: URL
        switch destination {
        case .claudeCode:
            guard let link = claudeCodeURL(for: repository.path),
                  let app = workspace.urlForApplication(toOpen: link) else {
                throw OpeningError.message("Install Claude Desktop to open this checkout in Claude Code.")
            }
            url = link
            application = app
        case .terminal:
            guard let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw OpeningError.message("Terminal could not be found on this Mac.")
            }
            url = URL(fileURLWithPath: repository.path, isDirectory: true)
            application = app
        }
        _ = try await workspace.open([url], withApplicationAt: application, configuration: .init())
    }

    private enum OpeningError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): message }
        }
    }
}
