import Foundation

struct DiffLineStat: Sendable {
    var added: Int = 0
    var deleted: Int = 0

    var total: Int {
        added + deleted
    }

    mutating func merge(_ other: DiffLineStat) {
        added += other.added
        deleted += other.deleted
    }

    static func fromPatch(_ patch: String) -> DiffLineStat {
        var stat = DiffLineStat()

        for line in patch.components(separatedBy: .newlines) {
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                continue
            }

            if line.hasPrefix("+") {
                stat.added += 1
            } else if line.hasPrefix("-") {
                stat.deleted += 1
            }
        }

        return stat
    }

    static func parseNumstatOutput(_ output: String) -> [String: DiffLineStat] {
        var statsByPath: [String: DiffLineStat] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            guard let added = Int(fields[0]), let deleted = Int(fields[1]) else {
                continue
            }

            let path = fields[2...].joined(separator: "\t")
            var existing = statsByPath[path] ?? DiffLineStat()
            existing.added += added
            existing.deleted += deleted
            statsByPath[path] = existing
        }

        return statsByPath
    }
}
