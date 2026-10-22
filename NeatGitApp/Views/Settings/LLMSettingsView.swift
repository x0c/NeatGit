import AppKit
import SwiftUI

struct LLMSettingsView: View {
    @Bindable var settingsStore: LLMSettingsStore
    @State private var updater = AppUpdater.shared
    @State private var contentHeight: CGFloat?
    @State private var isEditingPrompt = false

    var body: some View {
        Form {
            Section("服务连接") {
                TextField("服务地址", text: $settingsStore.baseURL)
                    .autocorrectionDisabled()
                    .help("填写兼容 OpenAI 的接口前缀，例如 https://api.deepseek.com 或 https://api.openai.com/v1。")
                    .accessibilityIdentifier("llm-base-url")

                TextField("模型", text: $settingsStore.model)
                    .autocorrectionDisabled()
                    .help("AI 提交始终使用此模型，不会自动切换。")
                    .accessibilityIdentifier("llm-model")

                SecureField("API 密钥", text: $settingsStore.apiKey)
                    .accessibilityIdentifier("llm-api-key")

                LabeledContent("生成说明") {
                    Button("编辑…") {
                        isEditingPrompt = true
                    }
                    .accessibilityIdentifier("llm-edit-prompt")
                }
                .help("发送给 AI 的系统提示词，可在调试窗口查看最终内容。")
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
            }

            Section {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "NeatGit").fontWeight(.medium)
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    Button("检查更新…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Button("退出") { NSApp.terminate(nil) }
                        .accessibilityLabel("退出 NeatGit")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { _, height in
            if height.isFinite, height > 0 {
                contentHeight = ceil(height)
            }
        }
        .scrollDisabled(true)
        .frame(width: 480, height: contentHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
        .sheet(isPresented: $isEditingPrompt) {
            SystemPromptEditor(settingsStore: settingsStore)
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { settingsStore.latestPersistenceError != nil },
                set: { if !$0 { settingsStore.clearPersistenceError() } }
            ),
            actions: {
                Button("知道了", role: .cancel) { settingsStore.clearPersistenceError() }
            },
            message: { Text(settingsStore.latestPersistenceError ?? "") }
        )
    }
}

private struct SystemPromptEditor: View {
    let settingsStore: LLMSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(settingsStore: LLMSettingsStore) {
        self.settingsStore = settingsStore
        _draft = State(initialValue: settingsStore.systemPrompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("生成说明").font(.headline)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .textEditorStyle(.automatic)
                .accessibilityLabel("系统提示词")
                .accessibilityIdentifier("llm-system-prompt")
            HStack {
                Button("恢复默认") { draft = settingsStore.defaultSystemPrompt }
                    .disabled(draft == settingsStore.defaultSystemPrompt)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("完成") {
                    settingsStore.systemPrompt = draft
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}
