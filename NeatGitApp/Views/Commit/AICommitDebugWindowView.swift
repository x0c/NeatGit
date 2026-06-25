import AppKit
import SwiftUI

struct AICommitDebugWindowView: View {
    static let windowID = "ai-commit-debug"

    let debugStore: AICommitDebugStore

    var body: some View {
        Group {
            if let session = debugStore.latestSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: session)

                        ForEach(session.attempts) { attempt in
                            attemptCard(attempt)
                        }
                    }
                    .padding(20)
                }
                .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "还没有 AI 调试记录",
                    systemImage: "ladybug",
                    description: Text("点击提交栏旁边的调试按钮，再执行一次 AI 生成 commit message，就能在这里看到最终发给模型的输入。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("AI Commit Debug")
        .toolbar {
            ToolbarItemGroup {
                Button("复制最新 User Prompt", action: copyLatestUserPrompt)
                    .disabled(debugStore.latestSession?.attempts.last == nil)

                Button("关闭") {
                    NSApp.keyWindow?.close()
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func header(for session: AICommitDebugSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.repositoryName)
                .font(.title2.weight(.semibold))

            Text(summaryText(for: session))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            infoGrid(
                rows: [
                    ("Base URL", session.baseURL),
                    ("Model", session.model),
                    ("开始时间", timestampText(for: session.startedAt)),
                    ("完成时间", session.completedAt.map(timestampText(for:)) ?? "进行中"),
                    ("最终结果", session.finalMessage ?? session.finalErrorMessage ?? "尚未完成")
                ]
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func attemptCard(_ attempt: AICommitDebugAttempt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(attempt.title)
                    .font(.headline)

                Spacer()

                Text(timestampText(for: attempt.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            debugSection(title: "System Prompt", text: attempt.systemPrompt)
            debugSection(title: "User Prompt", text: attempt.userPrompt)

            if let rawResponse = attempt.rawResponse, !rawResponse.isEmpty {
                debugSection(title: "Raw Response", text: rawResponse)
            }

            if let errorMessage = attempt.errorMessage, !errorMessage.isEmpty {
                debugSection(title: "Error", text: errorMessage)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func debugSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func infoGrid(rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)

                    Text(row.1)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func summaryText(for session: AICommitDebugSession) -> String {
        "共发现 \(session.changedFileCount) 个变更文件，实际参与 AI 分析 \(session.committableFileCount) 个，已记录 \(session.attempts.count) 轮请求。"
    }

    private func timestampText(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func copyLatestUserPrompt() {
        guard let prompt = debugStore.latestSession?.attempts.last?.userPrompt else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}
