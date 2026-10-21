import SwiftUI

struct LLMSettingsView: View {
    @Bindable var settingsStore: LLMSettingsStore
    @State private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("服务连接") {
                TextField("服务地址", text: $settingsStore.baseURL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("llm-base-url")

                TextField("模型", text: $settingsStore.model)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("llm-model")

                SecureField("API 密钥", text: $settingsStore.apiKey)
                    .accessibilityIdentifier("llm-api-key")

                Text("Base URL 填接口前缀即可，例如 DeepSeek 用 https://api.deepseek.com，OpenAI 可用 https://api.openai.com/v1。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("这里全局只配置一个模型，AI 提交不会自动切换模型；建议优先填写响应更快的轻量聊天模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("API Key 会保存在当前 macOS 用户的本地设置中，不再读取 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("更新") {
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticChecks($0) }
                    )
                )
                .disabled(!updater.canCheckForUpdates)

                Toggle(
                    "自动下载并安装更新",
                    isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.setAutomaticDownloads($0) }
                    )
                )
                .disabled(!updater.canCheckForUpdates || !updater.allowsAutomaticUpdates)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "NeatGit").fontWeight(.medium)
                        Text(
                            verbatim: Bundle.main.object(
                                forInfoDictionaryKey: "CFBundleShortVersionString"
                            ) as? String ?? ""
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("检查更新…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }

            Section("生成说明") {
                TextEditor(text: $settingsStore.systemPrompt)
                    .textEditorStyle(.automatic)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .accessibilityLabel("系统提示词")
                    .accessibilityIdentifier("llm-system-prompt")

                Button("恢复默认") {
                    settingsStore.resetSystemPrompt()
                }
                .disabled(
                    settingsStore.systemPrompt == settingsStore.defaultSystemPrompt
                )

                Text("System Prompt 会直接作为 AI 提交的系统提示词发送，可在调试窗口查看最终发出的内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 720, minHeight: 500, idealHeight: 600)
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { settingsStore.latestPersistenceError != nil },
                set: { shouldPresent in
                    if !shouldPresent {
                        settingsStore.clearPersistenceError()
                    }
                }
            ),
            actions: {
                Button("知道了", role: .cancel) {
                    settingsStore.clearPersistenceError()
                }
            },
            message: {
                Text(settingsStore.latestPersistenceError ?? "")
            }
        )
    }
}
