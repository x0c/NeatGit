import Foundation

final class GitRepositoryScanner: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let maxDepth = 6
    private static let overrideRootMaxDepth = 3
    private let excludedDirectoryNames: Set<String> = [
        ".Trash",
        ".cache",
        ".gradle",
        ".m2",
        ".npm",
        ".pnpm-store",
        ".vscode",
        "Applications",
        "Desktop",
        "Documents",
        "Downloads",
        "Library",
        "Movies",
        "Music",
        "Pictures",
        "Public",
        "Carthage",
        "DerivedData",
        "Pods",
        "build",
        "dist",
        "node_modules"
    ]

    func scan() async -> [GitRepository] {
        // `--repository-root` 指定的根目录只扫它自己那一棵树，深度不跟随主目录的上限。
        let overrideRoot = LaunchOptions.repositoryRoot
        let homeDirectory = overrideRoot ?? fileManager.homeDirectoryForCurrentUser
        let maxDepth = overrideRoot == nil ? self.maxDepth : Self.overrideRootMaxDepth
        let excludedDirectoryNames = self.excludedDirectoryNames

        let operation: @Sendable () -> [GitRepository] = {
            Self.findRepositories(
                homeDirectory: homeDirectory,
                maxDepth: maxDepth,
                excludedDirectoryNames: excludedDirectoryNames
            )
        }

        return await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private static func findRepositories(
        homeDirectory: URL,
        maxDepth: Int,
        excludedDirectoryNames: Set<String>
    ) -> [GitRepository] {
        var visitedPaths = Set<String>()
        var repositories: [GitRepository] = []

        scanDirectory(
            homeDirectory,
            depth: 0,
            maxDepth: maxDepth,
            excludedDirectoryNames: excludedDirectoryNames,
            visitedPaths: &visitedPaths,
            repositories: &repositories
        )

        return repositories.sorted(by: GitRepository.sortComparator)
    }

    private static func scanDirectory(
        _ directory: URL,
        depth: Int,
        maxDepth: Int,
        excludedDirectoryNames: Set<String>,
        visitedPaths: inout Set<String>,
        repositories: inout [GitRepository]
    ) {
        let fileManager = FileManager.default

        guard depth <= maxDepth else { return }
        guard shouldVisit(
            directory: directory,
            depth: depth,
            excludedDirectoryNames: excludedDirectoryNames
        ) else { return }

        let canonicalPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard visitedPaths.insert(canonicalPath).inserted else { return }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            repositories.append(GitRepository(path: canonicalPath))
            return
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]) else {
                continue
            }

            guard values.isDirectory == true else { continue }
            guard values.isSymbolicLink != true else { continue }
            guard values.isPackage != true else { continue }

            scanDirectory(
                child,
                depth: depth + 1,
                maxDepth: maxDepth,
                excludedDirectoryNames: excludedDirectoryNames,
                visitedPaths: &visitedPaths,
                repositories: &repositories
            )
        }
    }

    private static func shouldVisit(
        directory: URL,
        depth: Int,
        excludedDirectoryNames: Set<String>
    ) -> Bool {
        let name = directory.lastPathComponent

        if depth > 0 && name.hasPrefix(".") {
            return false
        }

        return !excludedDirectoryNames.contains(name)
    }
}
