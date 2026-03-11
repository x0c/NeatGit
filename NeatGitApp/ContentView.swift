import Dispatch
import Foundation
import SwiftUI

struct GitRepository: Identifiable, Hashable {
    let path: String

    var id: String { path }

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var parentPath: String {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
    }
}

private struct RepositoryGroup: Identifiable, Hashable {
    let parentPath: String
    let title: String
    let repositories: [GitRepository]

    var id: String { parentPath }

    static func makeGroups(from repositories: [GitRepository]) -> [RepositoryGroup] {
        let repositoriesByParent = Dictionary(grouping: repositories, by: \.parentPath)
        let titlesByParent = makeTitles(for: Array(repositoriesByParent.keys))

        return repositoriesByParent.map { parentPath, repositories in
            RepositoryGroup(
                parentPath: parentPath,
                title: titlesByParent[parentPath] ?? parentPath,
                repositories: repositories.sorted(by: GitRepository.sortComparator)
            )
        }
        .sorted { lhs, rhs in
            let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleComparison == .orderedSame {
                return lhs.parentPath.localizedCaseInsensitiveCompare(rhs.parentPath) == .orderedAscending
            }

            return titleComparison == .orderedAscending
        }
    }

    private static func makeTitles(for parentPaths: [String]) -> [String: String] {
        let pathComponents = Dictionary(uniqueKeysWithValues: parentPaths.map { path in
            let components = URL(fileURLWithPath: path)
                .standardizedFileURL
                .pathComponents
                .filter { $0 != "/" }
            return (path, components)
        })

        return Dictionary(uniqueKeysWithValues: parentPaths.map { path in
            let components = pathComponents[path] ?? []

            guard !components.isEmpty else {
                return (path, path)
            }

            for suffixLength in 1...components.count {
                let suffix = components.suffix(suffixLength).joined(separator: "/")
                let isUnique = parentPaths.allSatisfy { otherPath in
                    guard otherPath != path else { return true }
                    let otherComponents = pathComponents[otherPath] ?? []
                    return otherComponents.suffix(suffixLength).joined(separator: "/") != suffix
                }

                if isUnique || suffixLength == components.count {
                    return (path, suffix)
                }
            }

            return (path, path)
        })
    }
}

private extension GitRepository {
    static func sortComparator(_ lhs: GitRepository, _ rhs: GitRepository) -> Bool {
        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison == .orderedSame {
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        return nameComparison == .orderedAscending
    }
}

@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [GitRepository] = []
    @Published private(set) var isScanning = false

    private let scanner = GitRepositoryScanner()

    func refresh() {
        guard !isScanning else { return }

        isScanning = true

        Task {
            let repositories = await scanner.scan()
            self.repositories = repositories
            self.isScanning = false
        }
    }
}

struct ContentView: View {
    @StateObject private var store = RepositoryStore()
    @State private var selectionPath: GitRepository.ID?
    @State private var expandedGroupID: RepositoryGroup.ID?

    private var repositoryGroups: [RepositoryGroup] {
        RepositoryGroup.makeGroups(from: store.repositories)
    }

    private var selectedRepository: GitRepository? {
        guard let selectionPath else { return nil }
        return store.repositories.first { $0.id == selectionPath }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("项目")
                            .font(.title3.weight(.semibold))

                        Text(store.isScanning ? "正在扫描本机 Git 仓库" : "已发现 \(store.repositories.count) 个项目")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        store.refresh()
                    } label: {
                        if store.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isScanning)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                List(selection: $selectionPath) {
                    ForEach(repositoryGroups) { group in
                        Button {
                            toggleGroup(group.id)
                        } label: {
                            RepositoryGroupRow(
                                group: group,
                                isExpanded: expandedGroupID == group.id
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(sidebarBackground)

                        if expandedGroupID == group.id {
                            ForEach(group.repositories) { repository in
                                RepositoryRow(repository: repository)
                                    .padding(.leading, 20)
                                    .tag(repository.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(sidebarBackground)
            }
            .background(sidebarBackground)
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
            .overlay {
                if store.repositories.isEmpty {
                    ContentUnavailableView(
                        "暂无项目",
                        systemImage: "folder.badge.questionmark",
                        description: Text(store.isScanning ? "正在扫描..." : "点击列表右上角刷新，或等待首次自动扫描完成")
                    )
                }
            }
        } detail: {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("右侧区域暂未开发")
                    .font(.title3.weight(.semibold))

                Text(selectedRepository?.path ?? "先完成左侧项目列表，后续再补项目详情和操作区。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackground)
        }
        .background(detailBackground)
        .task {
            guard store.repositories.isEmpty else { return }
            store.refresh()
        }
        .onChange(of: store.repositories) { _, repositories in
            let repositoryIDs = Set(repositories.map(\.id))

            if let selectionPath, !repositoryIDs.contains(selectionPath) {
                self.selectionPath = nil
            }

            syncGroupState()
        }
        .onChange(of: selectionPath) { _, selectionPath in
            guard
                let selectionPath,
                let repository = store.repositories.first(where: { $0.id == selectionPath })
            else {
                return
            }

            expandedGroupID = repository.parentPath
        }
    }

    private func toggleGroup(_ groupID: RepositoryGroup.ID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedGroupID = expandedGroupID == groupID ? nil : groupID
        }
    }

    private func syncGroupState() {
        let currentGroupIDs = Set(repositoryGroups.map(\.id))

        if let expandedGroupID, currentGroupIDs.contains(expandedGroupID) {
            return
        }

        if let selectionPath,
           let repository = store.repositories.first(where: { $0.id == selectionPath }) {
            expandedGroupID = repository.parentPath
            return
        }

        expandedGroupID = repositoryGroups.first?.id
    }
}

private extension ContentView {
    var sidebarBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    var detailBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

private struct RepositoryGroupRow: View {
    let group: RepositoryGroup
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.repositories.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct RepositoryRow: View {
    let repository: GitRepository

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(repository.name)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private final class GitRepositoryScanner {
    private let fileManager = FileManager.default
    private let maxDepth = 6
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
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let maxDepth = self.maxDepth
        let excludedDirectoryNames = self.excludedDirectoryNames

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Self.findRepositories(
                        homeDirectory: homeDirectory,
                        maxDepth: maxDepth,
                        excludedDirectoryNames: excludedDirectoryNames
                    )
                )
            }
        }
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
