import XCTest

@MainActor
final class NativeWorkspaceTests: XCTestCase {
    func testRepositorySelectionPreviewAndNativeWindows() throws {
        continueAfterFailure = false
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let app = XCUIApplication()
        app.launch()
        let sidebar = app.descendants(matching: .any)["repository-sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 30), "应显示系统仓库列表。")

        let group = app.descendants(matching: .any)["repository-group-\(fixture.deletingLastPathComponent().path)"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30), "应扫描到隔离的测试仓库分组。")
        let repository = app.descendants(matching: .any)["repository-\(fixture.path)"].firstMatch
        if !repository.exists {
            let disclosure = group.disclosureTriangles.firstMatch
            if disclosure.exists {
                disclosure.click()
            } else {
                group.click()
            }
        }
        XCTAssertTrue(repository.waitForExistence(timeout: 5))
        repository.click()

        let file = app.descendants(matching: .any)["file-changed:原生界面验证.swift"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), "选择仓库后应读取真实文件状态。")
        file.click()
        let changesOnly = app.descendants(matching: .any)["diff-changes-only"].firstMatch
        XCTAssertTrue(changesOnly.waitForExistence(timeout: 15), "选择文本文件后应提供差异预览操作。")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "差异应由原生 WebView 承载。")
        changesOnly.click()
        changesOnly.click()

        let editor = app.textViews["commit-message-editor"].firstMatch
        XCTAssertTrue(editor.exists, "提交说明应使用可访问的系统文本编辑器。")
        editor.click()
        editor.typeText("test: native controls\n\nsecond line")
        XCTAssertTrue((editor.value as? String)?.contains("second line") == true, "应保留多行输入。")
        let beforeUndo = editor.value as? String
        app.typeKey("z", modifierFlags: .command)
        XCTAssertNotEqual(editor.value as? String, beforeUndo, "系统撤销应改变输入内容。")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        app.buttons["open-ai-debug"].click()
        XCTAssertTrue(app.staticTexts["还没有 AI 调试记录"].waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "关闭调试窗口不能误关主窗口。")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.textFields["llm-base-url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["llm-api-key"].exists)
        app.buttons["llm-edit-prompt"].click()
        let promptEditor = app.textViews["llm-system-prompt"].firstMatch
        XCTAssertTrue(promptEditor.waitForExistence(timeout: 5))
        let savedPrompt = try XCTUnwrap(promptEditor.value as? String)
        promptEditor.click()
        app.typeKey("a", modifierFlags: .command)
        promptEditor.typeText("Cancelled test draft")
        app.buttons["取消"].click()
        app.buttons["llm-edit-prompt"].click()
        XCTAssertTrue(promptEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(promptEditor.value as? String, savedPrompt)
        app.buttons["完成"].click()
        app.buttons["llm-edit-prompt"].click()
        XCTAssertTrue(promptEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(promptEditor.value as? String, savedPrompt)
        app.buttons["取消"].click()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "macOS 26 原生设置窗口"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
    }

    private func makeFixture() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("NeatGit-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["init", "--quiet", directory.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "应成功建立临时仓库，不创建任何提交。")
            try "let greeting = \"原生界面验证\"\n".write(
                to: directory.appendingPathComponent("原生界面验证.swift"),
                atomically: true,
                encoding: .utf8
            )
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
