import Foundation

struct CommitMessageCandidate: Decodable, Sendable {
    let type: String?
    let scope: String?
    let subject: String
    let body: [String]?
    let confidence: Double?
    let reasons: [String]?

    var composedMessage: String {
        var parts: [String] = []

        var subjectLine = subject
        if let type, !type.isEmpty {
            if let scope, !scope.isEmpty {
                subjectLine = "\(type)(\(scope)): \(subject)"
            } else {
                subjectLine = "\(type): \(subject)"
            }
        }
        parts.append(subjectLine)

        if let body, !body.isEmpty {
            parts.append("")
            parts.append(body.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n")
    }

    static func decode(from response: String) -> CommitMessageCandidate? {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return nil }

        let candidateStrings = [
            trimmedResponse,
            extractJSONObject(from: trimmedResponse)
        ]
        .compactMap { $0 }

        let decoder = JSONDecoder()

        for candidateString in candidateStrings {
            guard let data = candidateString.data(using: .utf8) else { continue }
            if let candidate = try? decoder.decode(CommitMessageCandidate.self, from: data) {
                return candidate
            }
        }

        return nil
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }

        guard start <= end else { return nil }
        return String(text[start...end])
    }
}
