import SwiftUI

struct CommitComposerBar: View {
    let repository: GitRepository?
    @Binding var commitMessage: String
    let isRunningCommitAction: Bool
    let isGeneratingMessage: Bool
    let statusMessage: String
    let onOpenDebugWindow: () -> Void
    let onGenerateMessage: () -> Void
    let onCommitAndPush: () -> Void
    let onCommitOnly: () -> Void

    private var isCommitEnabled: Bool {
        repository != nil
            && !isRunningCommitAction
            && !isGeneratingMessage
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $commitMessage)
                    .textEditorStyle(.plain)
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(8)
                    .disabled(repository == nil || isRunningCommitAction)
                    .accessibilityLabel("提交说明")
                    .accessibilityIdentifier("commit-message-editor")

                if commitMessage.isEmpty {
                    Text(commitPlaceholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 84, idealHeight: 96, maxHeight: 140)
            .background(.background)

            HStack(spacing: 8) {
                Button(action: onOpenDebugWindow) {
                    Label("AI 调试", systemImage: "ladybug")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("打开 AI 提交调试窗口")
                .accessibilityIdentifier("open-ai-debug")

                Button(action: onGenerateMessage) {
                    Label(isGeneratingMessage ? "正在生成…" : "AI 生成", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(repository == nil || isRunningCommitAction || isGeneratingMessage)
                .help("AI 生成提交说明")
                .accessibilityIdentifier("generate-commit-message")

                if isGeneratingMessage || isRunningCommitAction {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(isGeneratingMessage ? "正在生成提交说明" : "正在提交")
                }

                Spacer(minLength: 0)

                Menu("提交并推送") {
                    Button("仅提交到本地", action: onCommitOnly)
                } primaryAction: {
                    onCommitAndPush()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCommitEnabled)
                .accessibilityIdentifier("commit-menu")
            }
            .controlSize(.small)

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
    }

    private var commitPlaceholder: String {
        repository == nil ? "选择仓库后输入提交说明" : "输入提交说明"
    }
}
