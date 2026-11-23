import Foundation

public enum RepositoryDiscovery {
    private static let ignoredDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "Carthage", "DerivedData", "build", "dist", "target", ".build", "coverage"
    ]

    public static func scan(_ root: URL) async throws -> [Repository] {
        let fileManager = FileManager.default
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let children = try fileManager.contentsOfDirectory(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var repositories: [Repository] = []
        var found: Set<String> = []
        let client = GitClient()
        for child in children {
            try Task.checkCancellation()
            guard !ignoredDirectories.contains(child.lastPathComponent),
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let canonical = child.standardizedFileURL.resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: canonical.appendingPathComponent(".git").path),
                  let repo = try? await client.validate(path: canonical.path),
                  repo.path == canonical.path,
                  found.insert(repo.path).inserted else { continue }
            repositories.append(repo)
        }
        return repositories.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
