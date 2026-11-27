import AppKit
import XCTest
@testable import NeatGit

final class InteractionProfilerTests: XCTestCase {
    func testSynchronousMeasurementPreservesReturnValueAndIntervalCanEndOnce() {
        let value = InteractionProfiler.measure("测试.同步区间") { 42 }
        XCTAssertEqual(value, 42)

        let interval = InteractionProfiler.begin("测试.手动区间")
        interval.end("完成")
        interval.end("重复结束不应产生第二个样本")
    }

    func testSnapshotExposesReusableIndexesAndCommitCounts() {
        let files = (0..<12).map { index in
            RepositoryFileItem(
                section: .changed,
                path: "Sources/模块\(index % 2)/文件\(index).swift",
                kind: .file,
                state: .untracked,
                gitStatusCode: "??",
                previousPath: nil
            )
        }
        let ignoredByDefault = RepositoryFileItem(
            section: .changed,
            path: ".gitignore",
            kind: .file,
            state: .untracked,
            gitStatusCode: "??",
            previousPath: nil
        )
        let snapshot = RepositoryFileSnapshot(
            repositoryPath: "/测试项目",
            changedFiles: files + [ignoredByDefault],
            skippedFiles: [],
            ignoredFiles: []
        )

        XCTAssertEqual(snapshot.file(withID: files[7].id), files[7])
        XCTAssertEqual(snapshot.committableCount, files.count)
        XCTAssertEqual(snapshot.excludedFromCommitCount, 1)
        XCTAssertEqual(snapshot.smartGroups(in: .changed)?.count, 3)
        XCTAssertEqual(snapshot.allFiles.count, files.count + 1)
    }

    func testNativeDiffContentPreparesTextViewArraysOffTheApplyPath() throws {
        let rows = (0..<3).map { index in
            RepositoryDiffRow(
                kind: index == 1 ? .modified : .context,
                original: RepositoryDiffLine(text: "旧 \(index)", lineNumber: index + 1),
                modified: RepositoryDiffLine(text: index == 1 ? "新 \(index)" : "旧 \(index)", lineNumber: index + 1),
                originalChangedRanges: [],
                modifiedChangedRanges: []
            )
        }
        let document = RepositoryDiffDocument(
            repositoryPath: "/测试项目",
            filePath: "Sample.swift",
            mode: .workingTree,
            originalText: "",
            modifiedText: "",
            languageHint: "swift",
            rows: rows,
            originalLines: rows.count,
            modifiedLines: rows.count
        )

        let result = try NativeDiffRenderBuilder.render(
            document: document,
            layout: .sideBySide,
            showChangesOnly: false,
            expanded: [],
            id: 7
        )
        let content = try XCTUnwrap(result.panes.first)

        XCTAssertEqual(content.numberTexts, ["1", "2", "3"])
        XCTAssertEqual(content.expanderKeys, [-1, -1, -1])
        XCTAssertEqual(content.lineStyles.count, content.lines.count)
        XCTAssertEqual(content.paragraphStarts.count, content.lines.count)
        XCTAssertEqual(content.id, 7)
    }
}

@MainActor
final class NativeDiffFastPathTests: XCTestCase {
    func testSmallDocumentIsAppliedWithoutWaitingForAsyncScheduling() {
        let container = NativeDiffContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 1_000, height: 500)
        let coordinator = NativeDiffView.Coordinator()
        let document = NativeDiffRenderSample.makeDocument(original: "旧内容\n", modified: "新内容\n")

        coordinator.render(into: container, document: document, layout: .sideBySide, showChangesOnly: false)

        let textViews = container.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NativeDiffTextView }
        XCTAssertEqual(textViews.count, 2)
        XCTAssertTrue(textViews.contains { $0.textStorage?.string.contains("新内容") == true })
        XCTAssertFalse(container.subviews.compactMap { $0 as? NSProgressIndicator }.contains { $0.isHidden == false })
        coordinator.stop()
    }
}
