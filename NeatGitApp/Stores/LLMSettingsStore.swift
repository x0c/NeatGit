import Foundation
import Observation

@MainActor
@Observable
final class LLMSettingsStore {
    private enum StorageKey {
        static let baseURL = "llm.baseURL"
        static let model = "llm.model"
        static let apiKey = "llm.apiKey"
        static let systemPrompt = "llm.systemPrompt"
    }

    private enum DefaultValue {
        static let baseURL = "https://api.deepseek.com"
        static let model = "deepseek-v4-flash"
        static let systemPrompt = CommitPromptBuilder.defaultSystemPrompt
    }

    var baseURL: String {
        didSet {
            defaults.set(baseURL, forKey: StorageKey.baseURL)
        }
    }

    var model: String {
        didSet {
            defaults.set(model, forKey: StorageKey.model)
        }
    }

    var apiKey: String {
        didSet {
            defaults.set(apiKey, forKey: StorageKey.apiKey)
        }
    }

    var systemPrompt: String {
        didSet {
            defaults.set(systemPrompt, forKey: StorageKey.systemPrompt)
        }
    }

    private(set) var latestPersistenceError: String?

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURL = defaults.string(forKey: StorageKey.baseURL) ?? DefaultValue.baseURL
        self.model = defaults.string(forKey: StorageKey.model) ?? DefaultValue.model
        self.apiKey = defaults.string(forKey: StorageKey.apiKey) ?? ""
        self.systemPrompt = defaults.string(forKey: StorageKey.systemPrompt) ?? DefaultValue.systemPrompt
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedSystemPrompt: String {
        systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !trimmedBaseURL.isEmpty && !trimmedModel.isEmpty && !trimmedAPIKey.isEmpty
    }

    var effectiveSystemPrompt: String {
        trimmedSystemPrompt.isEmpty ? DefaultValue.systemPrompt : trimmedSystemPrompt
    }

    var defaultSystemPrompt: String {
        DefaultValue.systemPrompt
    }

    func makeConfiguration() throws -> LLMProviderConfiguration {
        guard !trimmedBaseURL.isEmpty else {
            throw GitCommandError(message: "请先在设置中填写 Base URL。")
        }

        guard let baseURL = URL(string: trimmedBaseURL) else {
            throw GitCommandError(message: "设置中的 Base URL 无法识别。")
        }

        guard !trimmedModel.isEmpty else {
            throw GitCommandError(message: "请先在设置中填写模型名。")
        }

        guard !trimmedAPIKey.isEmpty else {
            throw GitCommandError(message: "请先在设置中填写 API Key。")
        }

        return LLMProviderConfiguration(
            baseURL: baseURL,
            apiKey: trimmedAPIKey,
            model: trimmedModel
        )
    }

    func clearPersistenceError() {
        latestPersistenceError = nil
    }

    func resetSystemPrompt() {
        systemPrompt = DefaultValue.systemPrompt
    }
}
