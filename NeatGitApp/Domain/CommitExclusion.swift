import Foundation

enum CommitExclusion {
    static func shouldExcludeFromDefaultCommit(_ item: RepositoryFileItem) -> Bool {
        let fileName = (item.path as NSString).lastPathComponent
        return fileName == ".gitignore"
    }
}
