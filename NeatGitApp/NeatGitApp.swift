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
            NeatGitUpdateCommands()
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

private struct NeatGitUpdateCommands: Commands {
    @State private var updater = AppUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
