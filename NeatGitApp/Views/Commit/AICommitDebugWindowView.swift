import AppKit
import SwiftUI

struct AICommitDebugWindowView: View {
    static let windowID = "ai-commit-debug"

    @Environment(\.dismissWindow) private var dismissWindow
    let debugStore: AICommitDebugStore

    var body: some View {
        Group {
            if let session = debugStore.latestSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: session)

                        ForEach(session.attempts) { attempt in
                            attemptGroup(attempt)
                        }
                    }
                    .padding(20)
                }
                .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "还没有 AI 调试记录",
                    systemImage: "ladybug",
                    description: Text("执行一次 AI 生成提交说明后，可以在这里查看发给模型的输入和返回结果。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("AI 提交调试")
        .toolbar {
            ToolbarItem {
                Button("复制最新用户提示词", systemImage: "doc.on.doc", action: copyLatestUserPrompt)
                    .disabled(debugStore.latestSession?.attempts.last == nil)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("关闭", systemImage: "xmark") {
                    dismissWindow(id: Self.windowID)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(.background)
    }

    private func header(for session: AICommitDebugSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(summaryText(for: session))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    infoRow(title: "服务地址", value: session.baseURL)
                    infoRow(title: "模型", value: session.model)
                    infoRow(title: "开始时间", value: timestampText(for: session.startedAt))
                    infoRow(title: "完成时间", value: session.completedAt.map(timestampText(for:)) ?? "进行中")
                }

                debugSection(title: "最终结果", text: session.finalMessage ?? session.finalErrorMessage ?? "尚未完成")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(session.repositoryName)
                .font(.headline)
        }
    }

    private func attemptGroup(_ attempt: AICommitDebugAttempt) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("请求时间", value: timestampText(for: attempt.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                debugSection(title: "系统提示词", text: attempt.systemPrompt)
                debugSection(title: "用户提示词", text: attempt.userPrompt)

                if let rawResponse = attempt.rawResponse, !rawResponse.isEmpty {
                    debugSection(title: "原始响应", text: rawResponse)
                }

                if let errorMessage = attempt.errorMessage, !errorMessage.isEmpty {
                    debugSection(title: "错误信息", text: errorMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(attempt.title)
                .font(.headline)
        }
    }

    private func debugSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background)
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private func summaryText(for session: AICommitDebugSession) -> String {
        "共发现 \(session.changedFileCount) 个变更文件，实际参与 AI 分析 \(session.committableFileCount) 个，已记录 \(session.attempts.count) 轮请求。"
    }

    private func timestampText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func copyLatestUserPrompt() {
        guard let prompt = debugStore.latestSession?.attempts.last?.userPrompt else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}
