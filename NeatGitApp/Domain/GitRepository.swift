import Foundation

struct GitRepository: Identifiable, Hashable, Sendable {
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

extension GitRepository {
    static func sortComparator(_ lhs: GitRepository, _ rhs: GitRepository) -> Bool {
        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison == .orderedSame {
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        return nameComparison == .orderedAscending
    }
}
