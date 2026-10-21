import SwiftUI

@main
struct NeatGitApp: App {
    @State private var llmSettingsStore = LLMSettingsStore()
    @State private var aiCommitDebugStore = AICommitDebugStore()

    var body: some Scene {
        WindowGroup("NeatGit") {
            ContentView(
                llmSettingsStore: llmSettingsStore,
                aiCommitDebugStore: aiCommitDebugStore
            )
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
        }

        Window("AI 调试", id: AICommitDebugWindowView.windowID) {
            AICommitDebugWindowView(debugStore: aiCommitDebugStore)
        }
        .defaultSize(width: 900, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            LLMSettingsView(settingsStore: llmSettingsStore)
        }
        .defaultSize(width: 600, height: 640)
        .windowResizability(.contentSize)
    }
}
