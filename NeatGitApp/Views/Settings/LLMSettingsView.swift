import SwiftUI

struct LLMSettingsView: View {
    @Bindable var settingsStore: LLMSettingsStore

    var body: some View {
        Form {
            Section("AI 提交") {
                TextField("Base URL", text: $settingsStore.baseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $settingsStore.model)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key", text: $settingsStore.apiKey)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("System Prompt")
                            .font(.headline)

                        Spacer()

                        Button("恢复默认") {
                            settingsStore.resetSystemPrompt()
                        }
                        .buttonStyle(.link)
                    }

                    TextEditor(text: $settingsStore.systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }

                Text("Base URL 填接口前缀即可，例如 DeepSeek 用 https://api.deepseek.com，OpenAI 可用 https://api.openai.com/v1。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("这里全局只配置一个模型，AI 提交不会自动切换模型；建议优先填写响应更快的轻量聊天模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("System Prompt 会直接作为 AI 提交的系统提示词发送，可在调试窗口查看最终发出的内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("API Key 会保存在当前 macOS 用户的本地设置中，不再读取 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
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
