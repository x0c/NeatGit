import Foundation
import XCTest
@testable import NeatGit

/// 本地静态资源服务的安全回归：不得读到资源目录以外的文件。
///
/// 只验证纯路径解析，不启动也不触碰进程内的服务单例——
/// 一旦改了单例的资源根目录，同进程里随后运行的 Monaco 预览用例就会拿不到资源而集体超时。
final class BundleStaticFileServerTests: XCTestCase {
    func testTraversalOutsideRootIsRejected() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeatGit-静态服务-\(UUID().uuidString)")
        // 与资源目录同级、且名字以资源目录名为前缀：旧的字符串前缀校验会把它误判为子目录。
        let root = sandbox.appendingPathComponent("资源")
        let sibling = sandbox.appendingPathComponent("资源-机密")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try "<html>预览</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: root.appendingPathComponent("assets/main.js"), atomically: true, encoding: .utf8)
        try "机密内容".write(to: sibling.appendingPathComponent("密钥.txt"), atomically: true, encoding: .utf8)

        // 正常资源仍须放行，修复不能把预览自己挡死。
        for path in ["/", "/index.html", "/assets/main.js", "/index.html?v=1", "/sub/../index.html"] {
            XCTAssertNotNil(
                BundleStaticFileServer.resolveFileURL(for: path, rootDirectoryURL: root),
                "资源目录内的正常请求必须可取：\(path)"
            )
        }

        // 穿越到同级目录：原始形式与百分号编码形式都必须被拒绝。
        let traversalPaths = [
            "/../资源-机密/密钥.txt",
            "/%2e%2e/%E8%B5%84%E6%BA%90-%E6%9C%BA%E5%AF%86/%E5%AF%86%E9%92%A5.txt",
            "/assets/../../资源-机密/密钥.txt"
        ]

        for path in traversalPaths {
            XCTAssertNil(
                BundleStaticFileServer.resolveFileURL(for: path, rootDirectoryURL: root),
                "资源目录以外的文件绝不能被解析出来：\(path)"
            )
        }
    }

    func testDirectoriesAndMissingFilesAreNotServed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeatGit-静态服务-目录-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(BundleStaticFileServer.resolveFileURL(for: "/assets", rootDirectoryURL: root), "目录不应作为文件返回。")
        XCTAssertNil(BundleStaticFileServer.resolveFileURL(for: "/不存在.js", rootDirectoryURL: root))
    }
}
