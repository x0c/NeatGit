import Foundation

struct LLMChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct LLMChatCompletionResult: Sendable {
    let content: String
    let model: String?
    let usage: LLMChatUsage?
}

struct LLMChatUsage: Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

final class LLMChatService: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func complete(
        messages: [LLMChatMessage],
        configuration: LLMProviderConfiguration,
        temperature: Double = 0.1,
        maxTokens: Int = 500,
        responseFormat: LLMResponseFormat? = nil
    ) async throws -> LLMChatCompletionResult {
        let endpoint = try makeEndpoint(from: configuration.baseURL)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatCompletionRequest(
                model: configuration.model,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                responseFormat: responseFormat
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitCommandError(message: "AI 服务返回了无法识别的响应。")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let serviceError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data)
            let message = serviceError?.error.message
                ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitCommandError(
                message: message.isEmpty ? "AI 服务请求失败（HTTP \(httpResponse.statusCode)）。" : message
            )
        }

        let completion = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitCommandError(message: "AI 服务返回了空内容，可能是输入过长或模型不支持当前请求格式。")
        }

        return LLMChatCompletionResult(
            content: content,
            model: completion.model,
            usage: completion.usage.map { usage in
                LLMChatUsage(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    totalTokens: usage.totalTokens
                )
            }
        )
    }

    private func makeEndpoint(from baseURL: URL) throws -> URL {
        guard !baseURL.absoluteString.isEmpty else {
            throw GitCommandError(message: "AI 服务 Base URL 不能为空。")
        }

        if baseURL.path.hasSuffix("/chat/completions") {
            return baseURL
        }

        return baseURL
            .appendingPathComponent("chat", isDirectory: false)
            .appendingPathComponent("completions", isDirectory: false)
    }
}

enum LLMResponseFormat: String, Encodable, Sendable {
    case jsonObject = "json_object"
    case text = "text"

    var typeValue: String { rawValue }
}

private struct ResponseFormatWrapper: Encodable {
    let type: String
}

private struct OpenAIChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [LLMChatMessage]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: LLMResponseFormat?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)

        if let responseFormat {
            try container.encode(ResponseFormatWrapper(type: responseFormat.typeValue), forKey: .responseFormat)
        }
    }
}

private struct OpenAIChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]
    let model: String?
    let usage: Usage?

    struct Choice: Decodable, Sendable {
        let message: LLMChatMessage
    }

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct OpenAIErrorEnvelope: Decodable, Sendable {
    let error: OpenAIErrorBody
}

private struct OpenAIErrorBody: Decodable, Sendable {
    let message: String
}
