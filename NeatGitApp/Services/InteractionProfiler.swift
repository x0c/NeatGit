import Foundation
import os

/// 界面交互与后台阶段的统一性能量测入口。
///
/// 所有区间都会进入 Instruments 的 `os_signpost`；调试日志同时记录毫秒耗时，
/// 便于在没有 Instruments 的自动化回归里通过统一日志核对。只记录操作名、缓存命中、
/// 行数等低敏感信息，不把仓库路径、文件内容、提交说明或密钥写进性能日志。
enum InteractionProfiler {
    static let subsystem = "io.github.x0c.neatgit"
    static let category = "Interaction"

    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    private static let logger = Logger(subsystem: subsystem, category: category)

    /// 量测一段同步工作，返回值与抛错行为保持不变。
    static func measure<T>(
        _ name: StaticString,
        detail: @autoclosure () -> String = "",
        operation: () throws -> T
    ) rethrows -> T {
        let interval = Interval(name)
        defer { interval.end(detail()) }
        return try operation()
    }

    /// 量测主线程状态容器发起的一段异步工作。适合 Git 读取、AI 生成等完整链路。
    @MainActor
    static func measureAsync<T>(
        _ name: StaticString,
        detail: @autoclosure () -> String = "",
        operation: () async throws -> T
    ) async rethrows -> T {
        let interval = Interval(name)
        defer { interval.end(detail()) }
        return try await operation()
    }

    /// 记录没有持续区间的关键节点，例如缓存命中或旧任务结果丢弃。
    static func event(_ name: StaticString, detail: String = "") {
        signposter.emitEvent(name)
        logger.log("性能节点：\(String(describing: name), privacy: .public)；\(detail, privacy: .public)")
    }

    /// 开始一个需要跨回调结束的区间，例如「后台准备 → 主线程应用」。
    static func begin(_ name: StaticString) -> Interval {
        Interval(name)
    }

    /// 一个只能结束一次的量测区间；重复结束不会制造重复样本。
    final class Interval: @unchecked Sendable {
        private let name: StaticString
        private let state: OSSignpostIntervalState
        private let startedAt = ContinuousClock.now
        private let lock = NSLock()
        private var hasEnded = false

        fileprivate init(_ name: StaticString) {
            self.name = name
            state = InteractionProfiler.signposter.beginInterval(name)
        }

        func end(_ detail: String = "") {
            lock.lock()
            guard !hasEnded else {
                lock.unlock()
                return
            }
            hasEnded = true
            lock.unlock()

            let duration = startedAt.duration(to: .now)
            let milliseconds = Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1e15
            InteractionProfiler.signposter.endInterval(name, state)
            if milliseconds >= 1 {
                // 亚毫秒区间只进 signpost，避免日志持久化本身成为点击链路的固定开销。
                InteractionProfiler.logger.log(
                    "性能区间：\(String(describing: self.name), privacy: .public)；耗时：\(milliseconds, format: .fixed(precision: 3)) 毫秒；\(detail, privacy: .public)"
                )
            } else {
                InteractionProfiler.logger.debug(
                    "性能区间：\(String(describing: self.name), privacy: .public)；耗时：\(milliseconds, format: .fixed(precision: 3)) 毫秒；\(detail, privacy: .public)"
                )
            }
        }

        deinit {
            end("区间由销毁自动结束")
        }
    }
}
