import Foundation

struct CommitMessageCandidate: Decodable, Sendable {
    let type: String?
    let scope: String?
    let subject: String?
    let body: [String]?
    let confidence: Double?
    let reasons: [String]?

    var composedMessage: String {
        let subjectText = subject ?? ""

        guard !subjectText.isEmpty else {
            if let body, !body.isEmpty {
                return body.joined(separator: "\n")
            }
            return ""
        }

        var parts: [String] = []

        var subjectLine = subjectText
        if let type, !type.isEmpty {
            if let scope, !scope.isEmpty {
                subjectLine = "\(type)(\(scope)): \(subjectText)"
            } else {
                subjectLine = "\(type): \(subjectText)"
            }
        }
        parts.append(subjectLine)

        if let body, !body.isEmpty {
            parts.append("")
            parts.append(body.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)

        if let bodyArray = try? container.decodeIfPresent([String].self, forKey: .body) {
            body = bodyArray
        } else if let bodyString = try? container.decodeIfPresent(String.self, forKey: .body) {
            body = bodyString.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- •").union(.whitespaces)) }
                .filter { !$0.isEmpty }
        } else {
            body = nil
        }

        if let reasonsArray = try? container.decodeIfPresent([String].self, forKey: .reasons) {
            reasons = reasonsArray
        } else if let reasonsString = try? container.decodeIfPresent(String.self, forKey: .reasons) {
            reasons = reasonsString.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- •").union(.whitespaces)) }
                .filter { !$0.isEmpty }
        } else {
            reasons = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, scope, subject, body, confidence, reasons
    }

    static func decode(from response: String) -> CommitMessageCandidate? {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return nil }

        let candidateStrings = [
            extractJSONObject(from: trimmedResponse),
            extractJSONObjectFromMarkdown(from: trimmedResponse),
            trimmedResponse
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

    static func extractSubjectFromRawResponse(_ response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let candidate = decode(from: response) {
            return candidate.composedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.hasPrefix("{") {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let meaningfulLines = lines.filter { line in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return false }
            guard !stripped.hasPrefix("```") else { return false }
            guard !stripped.hasPrefix("//") else { return false }
            return true
        }

        guard let firstMeaningful = meaningfulLines.first else { return nil }

        return firstMeaningful
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` ").union(.whitespacesAndNewlines))
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }

        guard start <= end else { return nil }
        return String(text[start...end])
    }

    private static func extractJSONObjectFromMarkdown(from text: String) -> String? {
        let patterns = ["```json", "```"]
        for pattern in patterns {
            guard let blockStart = text.range(of: pattern) else { continue }
            let contentStart = text.index(after: blockStart.upperBound)

            guard let blockEnd = text.range(of: "```", range: contentStart..<text.endIndex) else { continue }

            let content = String(text[contentStart..<blockEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !content.isEmpty else { continue }
            return content
        }

        return nil
    }
}
