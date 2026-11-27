import Foundation
import XCTest
@testable import NeatGit

/// 提交安全性回归：两类会把不该提交的内容提交进去的真实缺陷。
///
/// 一是把「双方新增」这类合并冲突当成普通新增，默认提交时会用带冲突标记的工作区内容把它标记为已解决；
/// 二是文件名里的 `*`、`?`、`[` 等被 Git 当成通配模式，暂存时波及名字相近的邻居。
/// 每个用例都先核对本机 Git 的真实输出作为前提，再断言应用的行为。
final class CommitSafetyTests: XCTestCase {
    // MARK: - 未合并状态一律视为冲突

    /// 双方各自新增同名文件后合并，状态码是 `AA`（不含字母 U）。
    func testBothAddedConflictIsTreatedAsConflictAndStaysOutOfCommit() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let conflictPath = "同名.txt"
        try write("基线\n", named: "基线.txt", in: fixture)
        try commitAll("初始化", in: fixture)

        try runGit(["branch", "feature"], at: fixture)
        try write("主干内容\n", named: conflictPath, in: fixture)
        try commitAll("主干新增", in: fixture)

        try runGit(["checkout", "--quiet", "feature"], at: fixture)
        try write("分支内容\n", named: conflictPath, in: fixture)
        try commitAll("分支新增", in: fixture)

        try runGit(["checkout", "--quiet", "main"], at: fixture)
        try runGitAllowingFailure(["merge", "feature"], at: fixture)
        try write("普通修改\n", named: "基线.txt", in: fixture)

        // 前提自证：本机 Git 对「双方新增」给出的状态码确实是 AA。
        XCTAssertEqual(try statusCodesByPath(at: fixture)[conflictPath], "AA", "用例前提不成立：Git 未报出 AA 状态。")

        let repository = GitRepository(path: fixture.path)
        let snapshot = try await GitRepositoryStatusLoader().loadSnapshot(for: repository)
        let conflictItem = try XCTUnwrap(snapshot.changedFiles.first { $0.path == conflictPath })
        let headBefore = try runGit(["rev-parse", "HEAD"], at: fixture).trimmingCharacters(in: .whitespacesAndNewlines)

        // 用不断言中断的写法：即使前面的判断错了，也能继续看提交阶段真实发生了什么。
        // 双方新增的文件在我方既有提交里本来就有，所以要对比的是「提交前后内容不变且不含冲突标记」。
        let committedBefore = try committedFiles(in: fixture)
        XCTAssertEqual(conflictItem.gitStatusCode, "AA")
        XCTAssertTrue(conflictItem.hasConflict, "AA 属于未合并状态，应判为冲突。")
        XCTAssertFalse(conflictItem.isCheckableForCommit, "冲突文件不可勾选。")
        XCTAssertFalse(conflictItem.isCommittableByDefault, "冲突文件不进入默认提交范围。")
        XCTAssertEqual(conflictItem.statusSummary, "冲突", "不应显示成「新增」。")
        XCTAssertFalse(conflictItem.supportsWorkingTreeDiff, "冲突文件不走普通工作区差异。")
        XCTAssertFalse(conflictItem.supportsStagedDiff, "冲突文件不走普通暂存区差异。")

        let request = GitCommitRequest(
            repository: repository,
            message: "提交普通修改",
            changedItems: snapshot.changedFiles,
            action: .commitOnly
        )
        var commitError: Error?
        do {
            _ = try await GitRepositoryCommitService().run(request)
        } catch {
            commitError = error
        }

        let committed = try committedFiles(in: fixture)
        XCTAssertEqual(committed[conflictPath], committedBefore[conflictPath], "带冲突标记的工作区内容不得进入提交。")
        XCTAssertNil(committed[conflictPath]?.range(of: "<<<<<<<"), "提交里不得出现冲突标记。")
        XCTAssertEqual(try statusCodesByPath(at: fixture)[conflictPath], "AA", "应用不得替用户把冲突标记成已解决。")

        if commitError == nil {
            XCTAssertEqual(committed["基线.txt"], "普通修改\n", "提交成功时，普通修改应已提交。")
        } else {
            let headAfter = try runGit(["rev-parse", "HEAD"], at: fixture).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(headAfter, headBefore, "提交被拒时 HEAD 不得移动。")
        }
    }

    /// 其余未合并状态：UU / UD / DU 由真实合并产生；
    /// DD / AU / UA 没有简单的日常操作入口，用索引的阶段数据构造，事前同样核对 Git 的输出。
    func testOtherUnmergedStatesAreTreatedAsConflict() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let bothModified = "两边都改.txt"
        let deletedByUs = "我方删除.txt"
        let deletedByThem = "对方删除.txt"
        for path in [bothModified, deletedByUs, deletedByThem] {
            try write("基线\n", named: path, in: fixture)
        }
        try commitAll("初始化", in: fixture)
        try runGit(["branch", "feature"], at: fixture)

        try write("主干修改\n", named: bothModified, in: fixture)
        try FileManager.default.removeItem(at: fixture.appendingPathComponent(deletedByUs))
        try write("我方修改\n", named: deletedByThem, in: fixture)
        try commitAll("主干改动", in: fixture)

        try runGit(["checkout", "--quiet", "feature"], at: fixture)
        try write("分支修改\n", named: bothModified, in: fixture)
        try write("对方修改\n", named: deletedByUs, in: fixture)
        try FileManager.default.removeItem(at: fixture.appendingPathComponent(deletedByThem))
        try commitAll("分支改动", in: fixture)

        try runGit(["checkout", "--quiet", "main"], at: fixture)
        try runGitAllowingFailure(["merge", "feature"], at: fixture)

        let loader = GitRepositoryStatusLoader()
        let repository = GitRepository(path: fixture.path)
        let mergedSnapshot = try await loader.loadSnapshot(for: repository)
        for (path, expectedCode) in [(bothModified, "UU"), (deletedByUs, "DU"), (deletedByThem, "UD")] {
            XCTAssertEqual(try statusCodesByPath(at: fixture)[path], expectedCode, "用例前提不成立。")
            assertConflicted(mergedSnapshot.changedFiles.first { $0.path == path }, path: path, code: expectedCode)
        }

        // 只保留某一个阶段：1 → 双方删除（DD），2 → 我方新增（AU），3 → 对方新增（UA）。
        for (stage, expectedCode) in [(1, "DD"), (2, "AU"), (3, "UA")] {
            try keepOnlyStage(stage, of: bothModified, in: fixture)
            XCTAssertEqual(try statusCodesByPath(at: fixture)[bothModified], expectedCode, "用例前提不成立。")
            let snapshot = try await loader.loadSnapshot(for: repository)
            assertConflicted(snapshot.changedFiles.first { $0.path == bothModified }, path: bothModified, code: expectedCode)
        }
    }

    /// `man git-status` 对照表里的全部七种未合并组合逐一过模型判断；非冲突状态码作为对照。
    func testUnmergedStatusCodeTable() {
        for code in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            let item = makeItem(path: "冲突.txt", statusCode: code)
            XCTAssertTrue(item.hasConflict, "状态码 \(code) 是未合并状态，应判为冲突。")
            XCTAssertFalse(item.isCheckableForCommit, "状态码 \(code)：冲突文件不可勾选。")
            XCTAssertFalse(item.isCommittableByDefault, "状态码 \(code)：冲突文件不进入默认提交范围。")
        }

        for code in ["??", "A ", "AM", " M", "M ", "MM", "R ", "T ", "D "] {
            let item = makeItem(path: "普通.txt", statusCode: code)
            XCTAssertFalse(item.hasConflict, "状态码 \(code) 不是未合并状态。")
            XCTAssertTrue(item.isCheckableForCommit, "状态码 \(code) 不应被误判成冲突。")
        }

        XCTAssertFalse(makeItem(path: "跳过.txt", section: .skipped, statusCode: nil).hasConflict)
    }

    // MARK: - 路径按字面量处理

    func testFileNameWithStarStagesOnlyItself() async throws {
        try await assertStagingIsLiteral(specialNames: ["a*.txt"], neighbors: ["av.txt"])
    }

    func testOtherGlobCharactersAndLeadingColonAreLiteral() async throws {
        try await assertStagingIsLiteral(specialNames: ["a?.txt", "a[1].txt", ":av.txt"], neighbors: ["av.txt", "a1.txt"])
    }

    // MARK: - 断言与夹具

    private func assertConflicted(_ item: RepositoryFileItem?, path: String, code: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let item else {
            return XCTFail("状态列表里找不到 \(path)", file: file, line: line)
        }
        XCTAssertEqual(item.gitStatusCode, code, file: file, line: line)
        XCTAssertTrue(item.hasConflict, "\(code) 应判为冲突", file: file, line: line)
        XCTAssertFalse(item.isCheckableForCommit, "\(code)：冲突文件不可勾选", file: file, line: line)
        XCTAssertFalse(item.isCommittableByDefault, "\(code)：冲突文件不进入默认提交范围", file: file, line: line)
        XCTAssertEqual(item.statusSummary, "冲突", file: file, line: line)
    }

    /// 邻居是有意没勾选的已跟踪改动；只提交特殊文件名，邻居必须原样留在工作区。
    private func assertStagingIsLiteral(specialNames: [String], neighbors: [String]) async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture) }

        for neighbor in neighbors {
            try write("原内容\n", named: neighbor, in: fixture)
        }
        try commitAll("初始化", in: fixture)
        for neighbor in neighbors {
            try write("用户没勾选的改动\n", named: neighbor, in: fixture)
        }
        for specialName in specialNames {
            try write("特殊文件名\n", named: specialName, in: fixture)
        }

        let repository = GitRepository(path: fixture.path)
        let snapshot = try await GitRepositoryStatusLoader().loadSnapshot(for: repository)
        XCTAssertEqual(Set(snapshot.changedFiles.map(\.path)), Set(specialNames + neighbors), "用例前提不成立：状态列表与夹具不一致。")

        let selectedItems = snapshot.changedFiles.filter { specialNames.contains($0.path) }
        XCTAssertEqual(selectedItems.count, specialNames.count)
        let request = GitCommitRequest(
            repository: repository,
            message: "只提交特殊文件名",
            changedItems: selectedItems,
            action: .commitOnly
        )
        _ = try await GitRepositoryCommitService().run(request)

        let committed = try committedFiles(in: fixture)
        let codes = try statusCodesByPath(at: fixture)
        for specialName in specialNames {
            XCTAssertEqual(committed[specialName], "特殊文件名\n", "文件 \(specialName) 本身应被提交。")
        }
        for neighbor in neighbors {
            XCTAssertEqual(committed[neighbor], "原内容\n", "未勾选的邻居 \(neighbor) 不应被一并提交。")
            XCTAssertEqual(codes[neighbor], ".M", "邻居 \(neighbor) 的改动应仍停留在工作区。")
        }
    }

    private func makeItem(path: String, section: RepositoryFileSection = .changed, statusCode: String?) -> RepositoryFileItem {
        RepositoryFileItem(
            section: section,
            path: path,
            kind: .file,
            state: section == .changed ? .changed("任意") : .skipped,
            gitStatusCode: statusCode,
            previousPath: nil
        )
    }

    private func write(_ text: String, named name: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeatGit-提交安全验证-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            try runGit(["init", "--quiet", "--initial-branch=main"], at: directory)
            try runGit(["config", "user.name", "NeatGit"], at: directory)
            try runGit(["config", "user.email", "test@neatgit"], at: directory)
            try runGit(["config", "commit.gpgsign", "false"], at: directory)
            try runGit(["config", "merge.conflictstyle", "merge"], at: directory)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func commitAll(_ message: String, in directory: URL) throws {
        try runGit(["add", "-A"], at: directory)
        try runGit(["commit", "--quiet", "-m", message], at: directory)
    }

    /// 合并产生冲突时退出码为 1，属于预期结果。
    private func runGitAllowingFailure(_ arguments: [String], at directory: URL) throws {
        _ = try GitCommandRunner.run(in: directory.path, arguments: arguments)
    }

    @discardableResult
    private func runGit(_ arguments: [String], at directory: URL) throws -> String {
        let result = try GitCommandRunner.run(in: directory.path, arguments: arguments)
        let data = try GitCommandRunner.requireSuccess(result, defaultMessage: "Git 命令失败：\(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    /// 把某个未合并路径的索引阶段数据替换成只剩指定阶段。
    private func keepOnlyStage(_ stage: Int, of path: String, in directory: URL) throws {
        let entries = try runGit(["ls-files", "--unmerged", "-z", "--", path], at: directory).split(separator: "\0")
        guard let entry = entries.first else {
            throw GitCommandError(message: "路径 \(path) 当前没有未合并的阶段数据。")
        }

        // 先清掉该路径的全部阶段，再写回指定阶段；格式与 `git ls-files -u` 的输出一致。
        var input = Data("0 0000000000000000000000000000000000000000\t\(path)\n".utf8)
        var fields = entry.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 3, "用例前提不成立：阶段数据格式与预期不符。")
        fields[2] = Substring("\(stage)\t\(path)")
        input.append(fields.joined(separator: " ").data(using: .utf8)!)
        input.append(0x0A)

        let result = try GitCommandRunner.run(
            in: directory.path,
            arguments: ["update-index", "--index-info"],
            standardInputData: input
        )
        _ = try GitCommandRunner.requireSuccess(result, defaultMessage: "改写索引阶段数据失败。")
    }

    /// 直接取自 Git 输出的「路径 → 状态码」，作为独立于应用解析的对照。
    private func statusCodesByPath(at directory: URL) throws -> [String: String] {
        let result = try GitCommandRunner.run(
            in: directory.path,
            arguments: ["status", "--porcelain=v2", "--untracked-files=all", "-z"]
        )
        let data = try GitCommandRunner.requireSuccess(result, defaultMessage: "读取 Git 状态失败。")
        let records = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var codes: [String: String] = [:]
        var index = 0

        while index < records.count {
            let record = records[index]
            if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                codes[String(fields[8])] = String(fields[1])
            } else if record.hasPrefix("2 ") {
                // 改名记录后面跟着一条原始路径，跳过。
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                codes[String(fields[9])] = String(fields[1])
                index += 1
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                codes[String(fields[10])] = String(fields[1])
            } else if record.hasPrefix("? ") || record.hasPrefix("! ") {
                codes[String(record.dropFirst(2))] = String(record.prefix(2))
            }
            index += 1
        }

        return codes
    }

    /// 当前提交里的「路径 → 文本内容」。按对象编号读取，避免特殊文件名被当成版本表达式解析。
    private func committedFiles(in directory: URL) throws -> [String: String] {
        let tree = try runGit(["ls-tree", "-r", "-z", "HEAD"], at: directory)
        let entries = tree.split(separator: "\0").compactMap { record -> (path: String, object: String)? in
            let parts = record.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let header = parts[0].split(separator: " ")
            guard header.count == 3 else { return nil }
            return (String(parts[1]), String(header[2]))
        }
        let objects = try GitCommandRunner.readObjects(specifiers: entries.map(\.object), in: directory.path)

        var files: [String: String] = [:]
        for (entry, object) in zip(entries, objects) {
            files[entry.path] = object.map { String(decoding: $0, as: UTF8.self) }
        }
        return files
    }
}
