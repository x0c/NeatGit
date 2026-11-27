import XCTest
@testable import NeatGit

/// 点击链路中纯计算部分的性能回归。
///
/// 这里不设依赖机器负载的绝对耗时断言；XCTest 会保存每轮耗时，优化前后用同一物料对比。
final class InteractionPerformanceTests: XCTestCase {
    func testRepositoryGroupingPerformance() {
        let repositories = (0..<500).map { index in
            GitRepository(path: "/性能物料/模块\(index % 40)/子目录\(index % 7)/项目\(index)")
        }
        let starred = Set(repositories.prefix(20).map(\.id))

        measure {
            let groups = RepositoryGroup.makeGroups(from: repositories, starredRepositoryPaths: starred)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.repositories.count }, repositories.count)
        }
    }

    func testFileSmartGroupingPerformance() {
        let files = (0..<2_000).map { index in
            RepositoryFileItem(
                section: .changed,
                path: "Sources/模块\(index % 6)/功能\(index % 3)/文件\(index).swift",
                kind: .file,
                state: .untracked,
                gitStatusCode: "??",
                previousPath: nil
            )
        }

        measure {
            let groups = RepositoryFileSubgroup.makeSmartGroups(from: files)
            XCTAssertNotNil(groups)
        }
    }

    func testNativeDiffRenderPreparationPerformance() throws {
        let rows = (0..<10_000).map { index -> RepositoryDiffRow in
            let original = RepositoryDiffLine(text: "let value\(index) = \"原始内容\"", lineNumber: index + 1)
            let modified = RepositoryDiffLine(
                text: index % 20 == 0 ? "let value\(index) = \"修改内容\"" : original.text,
                lineNumber: index + 1
            )
            return RepositoryDiffRow(
                kind: index % 20 == 0 ? .modified : .context,
                original: original,
                modified: modified,
                originalChangedRanges: index % 20 == 0 ? [20..<24] : [],
                modifiedChangedRanges: index % 20 == 0 ? [20..<24] : []
            )
        }
        let document = RepositoryDiffDocument(
            repositoryPath: "/性能物料",
            filePath: "Large.swift",
            mode: .workingTree,
            originalText: "",
            modifiedText: "",
            languageHint: "swift",
            rows: rows,
            originalLines: rows.count,
            modifiedLines: rows.count
        )

        measure {
            do {
                let result = try NativeDiffRenderBuilder.render(
                    document: document,
                    layout: .sideBySide,
                    showChangesOnly: false,
                    expanded: [],
                    id: 1
                )
                XCTAssertEqual(result.panes.count, 2)
                XCTAssertEqual(result.panes[0].lines.count, rows.count)
            } catch {
                XCTFail("性能物料渲染不应失败：\(error)")
            }
        }
    }
}
