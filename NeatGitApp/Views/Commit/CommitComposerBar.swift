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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Label("提交说明", systemImage: "text.bubble")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if isGeneratingMessage || isRunningCommitAction {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(isGeneratingMessage ? "正在生成提交说明" : "正在提交")
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $commitMessage)
                    .textEditorStyle(.plain)
                    .autocorrectionDisabled()
                    .font(.body)
                    .padding(Theme.Spacing.xs)
                    .disabled(repository == nil || isRunningCommitAction || isGeneratingMessage)
                    .accessibilityLabel("提交说明")
                    .accessibilityIdentifier("commit-message-editor")

                if commitMessage.isEmpty {
                    Text(commitPlaceholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.sm)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 72)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }

            HStack(spacing: Theme.Spacing.sm) {
                Button(action: onOpenDebugWindow) {
                    Label("AI 调试", systemImage: "ladybug")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("打开 AI 提交调试窗口（排查生成结果用，日常提交不需要）")
                .accessibilityIdentifier("open-ai-debug")

                Button(action: onGenerateMessage) {
                    Label(isGeneratingMessage ? "正在生成…" : "AI 生成", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(repository == nil || isRunningCommitAction || isGeneratingMessage)
                .help("AI 生成提交说明")
                .accessibilityIdentifier("generate-commit-message")

                Spacer(minLength: 0)

                Menu(isRunningCommitAction ? "正在提交…" : "提交并推送") {
                    Button("仅提交到本地", action: onCommitOnly)
                    Text("仅提交到本地不会推送到远端，可稍后手动推送。")
                } primaryAction: {
                    onCommitAndPush()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCommitEnabled)
                .help("提交并推送会把本地 commit 同步到远端；仅提交到本地不会推送")
                .accessibilityIdentifier("commit-menu")
            }
            .controlSize(.small)

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("commit-status-message")
        }
        .padding(Theme.Spacing.md)
        .background(
            Theme.Palette.panelBackground,
            in: RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var commitPlaceholder: String {
        repository == nil ? "选择仓库后输入提交说明" : "输入提交说明"
    }
}
