import AppKit
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
        guard repository != nil else { return false }
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                CommitMessageTextView(
                    text: $commitMessage,
                    isEditable: repository != nil && !isRunningCommitAction
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 10)
                    .padding(.trailing, 34)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if commitMessage.isEmpty {
                    Text(commitPlaceholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 15)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 84)
            .background(commitEditorBackground)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    Button(action: onOpenDebugWindow) {
                        Image(systemName: "ladybug")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("打开 AI commit 调试窗口")

                    Button(action: onGenerateMessage) {
                        ZStack {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .opacity(isGeneratingMessage ? 0 : 1)

                            if isGeneratingMessage {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(repository == nil || isRunningCommitAction || isGeneratingMessage)
                    .help("AI 生成 commit message")
                }
                .padding(.trailing, 10)
                .padding(.bottom, 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            }

            ZStack(alignment: .trailing) {
                Menu("提交") {
                    Button("提交（不推送远程分支）", action: onCommitOnly)
                } primaryAction: {
                    onCommitAndPush()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .controlAccentColor))
                .disabled(!isCommitEnabled || isRunningCommitAction)
                .frame(maxWidth: .infinity)

                if isRunningCommitAction {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 12)
                        .allowsHitTesting(false)
                }
            }

            Text(statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }

    private var commitPlaceholder: String {
        if repository == nil {
            return "选择仓库后输入 commit message"
        }

        return "输入 commit message"
    }

    private var commitEditorBackground: Color {
        repository == nil || isRunningCommitAction
            ? Color(nsColor: .controlBackgroundColor)
            : Color.white
    }
}

private struct CommitMessageTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.textColor = isEditable ? .labelColor : .secondaryLabelColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
