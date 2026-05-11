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
        static let model = "deepseek-chat"
        static let systemPrompt = """
        你是一个资深工程师，负责为 Git 改动生成 commit message。
        任务目标：
        - 只总结这次会真正提交的改动
        - 优先总结这次提交的主线变化
        - 如果存在多个并列的重要改动，subject 需要合并表达这些主线，不要只取其中一个局部改动
        - 不要罗列所有细节，但也不要为了简短而遗漏同等重要的主线变化

        输出规则：
        - 只输出一个 JSON 对象，不要输出 Markdown、代码块、解释或前后缀
        - JSON 格式固定为：
          {"subject":"...", "confidence":0.0, "reasons":["..."]}
        - subject 必须单行、简体中文、准确、简洁
        - 改动类型明确时优先使用 Conventional Commit 前缀，例如 feat:、fix:、refactor:、docs:、chore:、test:
        - 如果同时存在代码改动与 Markdown / 文档 / 资源等非代码改动，subject 必须优先概括代码行为变化，非代码内容只作为次要背景
        - 如果同时存在生产代码改动与测试改动，subject 必须优先概括生产代码的业务变化，不要把“测试适配”写成主体
        - 只有当本次主要改动本身就是文档或说明文字时，才把 Markdown / 文档更新写成主体
        - 如果 diff 明确出现新增字段、入参、分支条件或核心服务逻辑，优先在 subject 中体现这些业务变化
        - 不要写“更新代码”“优化逻辑”“调整细节”“处理问题”这类空泛表述
        - reasons 用来说明你判断 subject 的依据，保留 1 到 3 条短语即可
        - confidence 取 0 到 1 之间的小数，表示你对 subject 准确性的判断
        """
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
