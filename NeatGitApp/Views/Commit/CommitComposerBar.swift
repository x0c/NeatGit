import SwiftUI

struct CommitComposerBar: View {
    @Binding var commitMessage: String
    let isRunningCommitAction: Bool
    let isGeneratingMessage: Bool
    let canCommit: Bool
    let statusMessage: String
    let onGenerateMessage: () -> Void
    let onCommitAndPush: () -> Void
    let onCommitOnly: () -> Void

    private var isBusy: Bool { isRunningCommitAction || isGeneratingMessage }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $commitMessage)
                        .textEditorStyle(.plain)
                        .autocorrectionDisabled()
                        .font(.body)
                        .disabled(isBusy)
                        .accessibilityLabel("提交说明")
                        .accessibilityIdentifier("commit-message-editor")

                    if commitMessage.isEmpty {
                        Text("提交说明")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.leading, Theme.Spacing.xs)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: Theme.Workspace.commitEditorHeight)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("commit-status-message")
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button(action: onGenerateMessage) {
                        Label(isGeneratingMessage ? "正在生成…" : "AI 生成", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canCommit || isBusy)
                    .help("AI 生成提交说明")
                    .accessibilityIdentifier("generate-commit-message")

                    Spacer(minLength: 0)

                    Menu(isRunningCommitAction ? "正在提交…" : "提交并推送") {
                        Button("仅提交到本地", action: onCommitOnly)
                    } primaryAction: {
                        onCommitAndPush()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit || isBusy || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("commit-menu")
                }
                .controlSize(.small)
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Palette.panelBackground)
    }
}
