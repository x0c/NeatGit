import AppKit
import Foundation

/// 启动参数：目前只有一个用途——把项目扫描的根目录从用户主目录换到别处。
///
/// 默认行为完全不变（没有参数就扫主目录）。指定根目录后只扫这一个目录树，
/// 用于把 NeatGit 指向一个已知目录（自动化、临时仓库、受限权限环境），
/// 既不用打开系统面板，也不会顺带列出主目录下其它项目。
enum LaunchOptions {
    static let repositoryRootArgument = "--repository-root"
    static let e2eTestingArgument = "--e2e-testing"
    static let e2eWindowSizeArgument = "--e2e-window-size"

    /// `--e2e-testing`：验收模式，当前只影响窗口呈现方式。
    static let isE2ETesting = CommandLine.arguments.contains(e2eTestingArgument)

    /// `--repository-root <path>` 指定的扫描根目录；未指定时为 nil。
    static let repositoryRoot: URL? = Self.parseRepositoryRoot(CommandLine.arguments)

    /// `--e2e-window-size WxH`：验收窗口的内容尺寸，默认 1400x860。
    static let e2eWindowSize: NSSize = Self.parseWindowSize(CommandLine.arguments) ?? NSSize(width: 1400, height: 860)

    static func parseWindowSize(_ arguments: [String]) -> NSSize? {
        guard let flagIndex = arguments.firstIndex(of: e2eWindowSizeArgument) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }

        let parts = arguments[valueIndex].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width >= 320, height >= 240 else { return nil }
        return NSSize(width: width, height: height)
    }

    static func parseRepositoryRoot(_ arguments: [String]) -> URL? {
        guard let flagIndex = arguments.firstIndex(of: repositoryRootArgument) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }

        let path = arguments[valueIndex]
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
