import Foundation
import Observation
import Sparkle

/// 应用内更新入口：Sparkle 拥有全部更新 UI，本类只做状态桥接与安装前收尾。
///
/// - 菜单与设置页观察 `canCheckForUpdates` 等状态，不直接观察 Sparkle 对象。
/// - 后台发现更新时不抢焦点（温和提醒），只有用户主动检查时才允许弹窗，避免打断提交操作。
/// - 覆盖安装前通过 `onWillInstallUpdate` 收尾（NeatGit 目前无须落盘，仅保留钩子）。
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var automaticallyDownloadsUpdates = true
    private(set) var allowsAutomaticUpdates = true

    /// 安装前收尾（由应用启动时注入，暂无须落盘的文档）。
    var onWillInstallUpdate: (@MainActor () -> Void)?

    @ObservationIgnored
    private lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    @ObservationIgnored
    private var observations: [NSKeyValueObservation] = []

    private override init() {
        super.init()
        _ = controller
        for keyPath in [
            \SPUUpdater.canCheckForUpdates,
            \SPUUpdater.automaticallyChecksForUpdates,
            \SPUUpdater.automaticallyDownloadsUpdates,
            \SPUUpdater.allowsAutomaticUpdates,
        ] as [KeyPath<SPUUpdater, Bool>] {
            observations.append(controller.updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    var sessionInProgress: Bool {
        controller.updater.sessionInProgress
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    private func refresh() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }

    // MARK: - SPUUpdaterDelegate（覆盖安装前收尾）

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in self.onWillInstallUpdate?() }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onWillInstallUpdate?()
    }

    // MARK: - SPUStandardUserDriverDelegate（温和提醒）

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }
}
