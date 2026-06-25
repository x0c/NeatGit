import Foundation

struct LLMProviderConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
}
