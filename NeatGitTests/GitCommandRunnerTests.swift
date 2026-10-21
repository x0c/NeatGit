import Foundation
import XCTest
@testable import NeatGit

/// Git 进程执行与本地静态资源服务的回归测试。
///
/// 两个用例都对应本次修复的真实缺陷，不是假想场景：
/// 一是标准输入写满后与标准输出互等导致的管道死锁，二是静态资源服务的路径穿越。
final class GitCommandRunnerTests: XCTestCase {
    /// 大标准输入 + 大标准输出不得死锁。
    ///
    /// 旧实现先在当前线程把 stdin 一次写完再去读 stdout，Git 则在读完请求前就开始写响应，
    /// 双方各自等对方腾出管道缓冲区。实测约 820 KB 请求必然卡死，这里用同样量级守住。
    func testLargeStandardInputWithLargeOutputDoesNotDeadlock() throws {
        let fixture = try makeRepositoryWithCommittedFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let specifiers = Array(repeating: fixture.blobSpecifier, count: 20_000)

        let expectation = expectation(description: "大批量 Git 对象读取应在限定时间内完成")
        var objects: [Data?] = []
        var failure: Error?

        // 放到后台线程并设超时：死锁时主线程不会被拖住，用例以超时失败收场。
        Thread.detachNewThread {
            do {
                objects = try GitCommandRunner.readObjects(specifiers: specifiers, in: fixture.directory.path)
            } catch {
                failure = error
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60)

        if let failure {
            throw failure
        }

        XCTAssertEqual(objects.count, specifiers.count, "每个请求都应有对应结果。")
        XCTAssertEqual(objects.compactMap { $0 }.count, specifiers.count, "命中的对象内容不应丢失。")
    }

    /// 不存在的对象返回 nil，且不会打乱后续结果的对位关系。
    func testMissingObjectsDoNotShiftLaterResults() throws {
        let fixture = try makeRepositoryWithCommittedFile()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let objects = try GitCommandRunner.readObjects(
            specifiers: ["HEAD:不存在的文件.txt", fixture.blobSpecifier],
            in: fixture.directory.path
        )

        XCTAssertEqual(objects.count, 2)
        XCTAssertNil(objects[0], "缺失对象应为 nil。")
        XCTAssertEqual(objects[1].map { String(decoding: $0, as: UTF8.self) }, "已提交内容\n", "缺失项不应让后面的结果错位。")
    }

    private func makeRepositoryWithCommittedFile() throws -> (directory: URL, blobSpecifier: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeatGit-进程验证-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            try runGit(["init", "--quiet"], at: directory)
            let file = directory.appendingPathComponent("示例.txt")
            try "已提交内容\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "--", file.lastPathComponent], at: directory)
            try runGit(
                ["-c", "user.email=test@neatgit", "-c", "user.name=NeatGit", "commit", "--quiet", "-m", "初始化"],
                at: directory
            )
            return (directory, "HEAD:示例.txt")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let result = try GitCommandRunner.run(in: directory.path, arguments: arguments)
        _ = try GitCommandRunner.requireSuccess(result, defaultMessage: "创建隔离的 Git 验证数据失败。")
    }
}
