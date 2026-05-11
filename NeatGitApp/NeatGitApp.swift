import SwiftUI

@main
struct NeatGitApp: App {
    @State private var llmSettingsStore = LLMSettingsStore()
    @State private var aiCommitDebugStore = AICommitDebugStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                llmSettingsStore: llmSettingsStore,
                aiCommitDebugStore: aiCommitDebugStore
            )
        }
        .defaultSize(width: 1100, height: 720)

        Window("AI Commit Debug", id: AICommitDebugWindowView.windowID) {
            AICommitDebugWindowView(debugStore: aiCommitDebugStore)
        }
        .defaultSize(width: 900, height: 720)

        Settings {
            LLMSettingsView(settingsStore: llmSettingsStore)
        }
    }
}
