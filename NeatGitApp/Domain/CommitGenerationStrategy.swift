import Foundation

enum CommitGenerationStrategy: String, Sendable {
    case singlePass
    case twoStepMapReduce
}

struct CommitGenerationStrategyThreshold: Sendable {
    var fileCount: Int
    var totalDiffLines: Int

    static let `default` = CommitGenerationStrategyThreshold(
        fileCount: 15,
        totalDiffLines: 500
    )

    func shouldUseMapReduce(fileCount: Int, totalDiffLines: Int) -> Bool {
        fileCount > self.fileCount || totalDiffLines > self.totalDiffLines
    }
}

struct CommitGenerationFeatureFlags: Sendable {
    var useFileSelectionBudget: Bool
    var useChangeKindPriority: Bool

    static let `default` = CommitGenerationFeatureFlags(
        useFileSelectionBudget: false,
        useChangeKindPriority: false
    )
}
