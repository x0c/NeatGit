import Foundation

struct RepositoryGroup: Identifiable, Hashable {
    let parentPath: String
    let title: String
    let repositories: [GitRepository]
    let starredRepositoryCount: Int

    var id: String { parentPath }

    static func makeGroups(
        from repositories: [GitRepository],
        starredRepositoryPaths: Set<GitRepository.ID> = []
    ) -> [RepositoryGroup] {
        let repositoriesByParent = Dictionary(grouping: repositories, by: \.parentPath)
        let titlesByParent = makeTitles(for: Array(repositoriesByParent.keys))

        return repositoriesByParent.map { parentPath, repositories in
            let starredRepositoryCount = repositories.reduce(into: 0) { count, repository in
                if starredRepositoryPaths.contains(repository.id) {
                    count += 1
                }
            }

            return RepositoryGroup(
                parentPath: parentPath,
                title: titlesByParent[parentPath] ?? parentPath,
                repositories: repositories.sorted { lhs, rhs in
                    let lhsIsStarred = starredRepositoryPaths.contains(lhs.id)
                    let rhsIsStarred = starredRepositoryPaths.contains(rhs.id)

                    if lhsIsStarred != rhsIsStarred {
                        return lhsIsStarred
                    }

                    return GitRepository.sortComparator(lhs, rhs)
                },
                starredRepositoryCount: starredRepositoryCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.starredRepositoryCount != rhs.starredRepositoryCount {
                return lhs.starredRepositoryCount > rhs.starredRepositoryCount
            }

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
