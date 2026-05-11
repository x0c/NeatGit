import AppKit
import SwiftUI

struct ContentView: View {
    private enum WindowChromePalette {
        static let topBarStart = Color(red: 0.15, green: 0.48, blue: 0.93)
        static let topBarEnd = Color(red: 0.03, green: 0.28, blue: 0.82)

        static let topBarBackground = LinearGradient(
            colors: [topBarStart, topBarEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private struct CommitAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private struct RepositoryFileActionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum FocusTarget: Hashable {
        case repositoryFiles
    }

    let llmSettingsStore: LLMSettingsStore
    let aiCommitDebugStore: AICommitDebugStore

    @Environment(\.openWindow) private var openWindow

    @State private var store = RepositoryStore()
    @State private var statusStore = RepositoryStatusStore()
    @State private var selectionPath: GitRepository.ID?
    @State private var expandedGroupID: RepositoryGroup.ID?
    @State private var commitMessage = ""
    @State private var expandedFileSections: Set<RepositoryFileSection> = [.changed]
    @State private var selectedFileIDs: Set<RepositoryFileItem.ID> = []
    @State private var fileSelectionAnchorID: RepositoryFileItem.ID?
    @State private var hoveredPreviewFileID: RepositoryFileItem.ID?
    @State private var isRunningCommitAction = false
    @State private var isGeneratingCommitMessage = false
    @State private var commitAlert: CommitAlert?
    @State private var repositoryFileActionAlert: RepositoryFileActionAlert?
    @FocusState private var focusedTarget: FocusTarget?

    private let gitIgnoreWriter = GitIgnoreWriter()
    private let commitService = GitRepositoryCommitService()
    private let skipWorktreeService = GitSkipWorktreeService()
    private let commitMessageGenerationService: CommitMessageGenerationService

    init(
        llmSettingsStore: LLMSettingsStore,
        aiCommitDebugStore: AICommitDebugStore
    ) {
        self.llmSettingsStore = llmSettingsStore
        self.aiCommitDebugStore = aiCommitDebugStore
        self.commitMessageGenerationService = CommitMessageGenerationService(debugStore: aiCommitDebugStore)
    }

    private var repositoryGroups: [RepositoryGroup] {
        RepositoryGroup.makeGroups(
            from: store.repositories,
            starredRepositoryPaths: store.starredRepositoryPaths
        )
    }

    private var selectedRepository: GitRepository? {
        guard let selectionPath else { return nil }
        return store.repositories.first { $0.id == selectionPath }
    }

    private var selectedFiles: [RepositoryFileItem] {
        guard let snapshot = statusStore.snapshot else { return [] }
        return snapshot.allFiles.filter { selectedFileIDs.contains($0.id) }
    }

    private var hoveredPreviewFile: RepositoryFileItem? {
        guard let snapshot = statusStore.snapshot, let hoveredPreviewFileID else { return nil }
        return snapshot.allFiles.first { $0.id == hoveredPreviewFileID }
    }

    private var commitStatusMessage: String {
        guard selectedRepository != nil else {
            return "选择仓库后，会自动暂存并提交可提交的文件更改。"
        }

        guard let snapshot = statusStore.snapshot else {
            return "正在读取仓库状态..."
        }

        let excludedGitIgnoreCount = snapshot.changedFiles.filter(isExcludedFromDefaultCommit(_:)).count
        let committableCount = snapshot.changedFiles.filter { item in
            item.isCheckableForCommit && !isExcludedFromDefaultCommit(item)
        }.count

        if committableCount > 0 {
            if excludedGitIgnoreCount > 0 {
                return "提交时会自动 add all 并提交 \(committableCount) 个文件更改，排除 \(excludedGitIgnoreCount) 个 .gitignore 文件和 skip-worktree 文件。"
            }

            return "提交时会自动 add all 并提交 \(committableCount) 个文件更改，排除 skip-worktree 文件。"
        }

        return "当前没有可提交的文件更改，默认会排除 .gitignore 和 skip-worktree 文件。"
    }

    var body: some View {
        NavigationSplitView { sidebar } detail: { detailPane }
        .background(Color.white)
        .background(WindowTitleBarConfigurator())
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarBackground(WindowChromePalette.topBarBackground, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .task {
            guard store.repositories.isEmpty else { return }
            store.refresh()
        }
        .task(id: selectionPath) {
            statusStore.load(for: selectedRepository)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            statusStore.refreshCurrentRepository()
        }
        .onChange(of: store.repositories) { _, repositories in
            let repositoryIDs = Set(repositories.map(\.id))

            if let selectionPath, !repositoryIDs.contains(selectionPath) {
                self.selectionPath = nil
            }

            syncGroupState()
        }
        .onChange(of: selectionPath) { _, selectionPath in
            selectedFileIDs = []
            fileSelectionAnchorID = nil
            hoveredPreviewFileID = nil

            guard
                let selectionPath,
                let repository = store.repositories.first(where: { $0.id == selectionPath })
            else {
                return
            }

            expandedGroupID = repository.parentPath
        }
        .onChange(of: statusStore.snapshot?.allFiles.map(\.id) ?? []) { _, fileIDs in
            reconcileFileSelection(with: fileIDs)
            reconcileHoveredPreview(with: fileIDs)
        }
        .alert(item: $repositoryFileActionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("知道了"))
            )
        }
        .alert(item: $commitAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("知道了"))
            )
        }
    }

    private var sidebar: some View {
        RepositorySidebar(
            groups: repositoryGroups,
            isScanning: store.isScanning,
            starredRepositoryPaths: store.starredRepositoryPaths,
            selectionPath: $selectionPath,
            expandedGroupID: $expandedGroupID,
            onToggleGroup: toggleGroup,
            onToggleRepositoryStar: store.toggleStar(for:)
        )
    }

    private var detailPane: some View {
        HSplitView {
            VStack(spacing: 0) {
                RepositoryFilePanel(
                    repository: selectedRepository,
                    snapshot: statusStore.snapshot,
                    isLoading: statusStore.isLoading,
                    errorMessage: statusStore.errorMessage,
                    expandedSections: expandedFileSections,
                    selectedFileIDs: selectedFileIDs,
                    selectionAnchorID: fileSelectionAnchorID,
                    onToggleSection: toggleFileSection,
                    onRefresh: statusStore.refreshCurrentRepository,
                    onActivatePanel: activateRepositoryFilePanel,
                    onSelectFiles: selectFiles,
                    onSelectFile: selectFile,
                    onHoverFile: handlePreviewHover(_:isHovering:),
                    onIgnorePath: ignorePath(for:),
                    onIgnoreFileName: ignoreFileName(for:),
                    onIgnoreDirectory: ignoreDirectory(_:for:),
                    onMarkAsSkipped: markAsSkipped(_:),
                    onRemoveFromSkipped: removeFromSkipped(_:)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focused($focusedTarget, equals: .repositoryFiles)
                .onMoveCommand(perform: handleRepositoryFileMoveCommand)

                Divider()

                CommitComposerBar(
                    repository: selectedRepository,
                    commitMessage: $commitMessage,
                    isRunningCommitAction: isRunningCommitAction,
                    isGeneratingMessage: isGeneratingCommitMessage,
                    statusMessage: commitStatusMessage,
                    onOpenDebugWindow: openCommitDebugWindow,
                    onGenerateMessage: handleGenerateCommitMessage,
                    onCommitAndPush: handleCommitAndPush,
                    onCommitOnly: handleCommitOnly
                )
            }
            .frame(minWidth: 260, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            .background(
                SplitViewInitialDividerPositioner(position: 350)
            )

            RepositoryPreviewPane(
                repository: selectedRepository,
                selectedFiles: selectedFiles,
                hoveredFile: hoveredPreviewFile,
                cacheRevision: statusStore.snapshotRevision
            )
            .frame(minWidth: 180, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarToggleButton(action: toggleSidebar)
            }
        }
    }

    private func toggleGroup(_ groupID: RepositoryGroup.ID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedGroupID = expandedGroupID == groupID ? nil : groupID
        }
    }

    private func syncGroupState() {
        let currentGroupIDs = Set(repositoryGroups.map(\.id))

        if let expandedGroupID, currentGroupIDs.contains(expandedGroupID) {
            return
        }

        if let selectionPath,
           let repository = store.repositories.first(where: { $0.id == selectionPath }) {
            expandedGroupID = repository.parentPath
            return
        }

        expandedGroupID = repositoryGroups.first?.id
    }

    private func handleGenerateCommitMessage() {
        guard !isGeneratingCommitMessage else { return }

        guard let repository = selectedRepository else {
            commitAlert = CommitAlert(
                title: "无法生成",
                message: "请先选择仓库。"
            )
            return
        }

        guard let snapshot = statusStore.snapshot, !snapshot.changedFiles.isEmpty else {
            commitAlert = CommitAlert(
                title: "无法生成",
                message: "当前仓库没有可分析的文件变更。"
            )
            return
        }

        let configuration: LLMProviderConfiguration

        do {
            configuration = try llmSettingsStore.makeConfiguration()
        } catch {
            commitAlert = CommitAlert(
                title: "AI 设置未完成",
                message: "\(GitCommandError.describe(error))\n\n可使用 cmd+, 打开设置页继续配置。"
            )
            return
        }

        isGeneratingCommitMessage = true

        Task {
            do {
                let generatedMessage = try await commitMessageGenerationService.generateMessage(
                    for: repository,
                    changedItems: snapshot.changedFiles,
                    configuration: configuration,
                    systemPrompt: llmSettingsStore.effectiveSystemPrompt
                )

                await MainActor.run {
                    isGeneratingCommitMessage = false
                    commitMessage = generatedMessage
                }
            } catch {
                await MainActor.run {
                    isGeneratingCommitMessage = false
                    commitAlert = CommitAlert(
                        title: "生成失败",
                        message: GitCommandError.describe(error)
                    )
                }
            }
        }
    }

    private func openCommitDebugWindow() {
        openWindow(id: AICommitDebugWindowView.windowID)
    }

    private func handleCommitAndPush() {
        runCommitAction(.commitAndPush)
    }

    private func handleCommitOnly() {
        runCommitAction(.commitOnly)
    }

    private func toggleFileSection(_ section: RepositoryFileSection) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedFileSections.contains(section) {
                expandedFileSections.remove(section)
            } else {
                expandedFileSections = [section]
            }
        }
    }

    private func selectFiles(
        _ fileIDs: Set<RepositoryFileItem.ID>,
        _ anchorID: RepositoryFileItem.ID?
    ) {
        selectedFileIDs = fileIDs
        fileSelectionAnchorID = fileIDs.isEmpty ? nil : anchorID
        activateRepositoryFilePanel()
    }

    private func selectFile(_ item: RepositoryFileItem) {
        selectedFileIDs = [item.id]
        fileSelectionAnchorID = item.id
        activateRepositoryFilePanel()
    }

    private func activateRepositoryFilePanel() {
        focusedTarget = .repositoryFiles
    }

    private func handleRepositoryFileMoveCommand(_ direction: MoveCommandDirection) {
        guard focusedTarget == .repositoryFiles else { return }

        switch direction {
        case .up:
            moveFileSelection(offset: -1)
        case .down:
            moveFileSelection(offset: 1)
        default:
            break
        }
    }

    private func moveFileSelection(offset: Int) {
        guard
            let targetItem = targetFileItemForKeyboardNavigation(offset: offset)
        else {
            return
        }

        selectFile(targetItem)
    }

    private func targetFileItemForKeyboardNavigation(offset: Int) -> RepositoryFileItem? {
        guard let snapshot = statusStore.snapshot else { return nil }

        let visibleItems = RepositoryFileSection.allCases.reduce(into: [RepositoryFileItem]()) { result, section in
            guard expandedFileSections.contains(section) else { return }
            result.append(contentsOf: snapshot.files(in: section))
        }

        guard !visibleItems.isEmpty else { return nil }

        let currentID =
            fileSelectionAnchorID ??
            selectedFileIDs.first

        guard let currentID else {
            return offset > 0 ? visibleItems.first : visibleItems.last
        }

        guard let currentIndex = visibleItems.firstIndex(where: { $0.id == currentID }) else {
            return offset > 0 ? visibleItems.first : visibleItems.last
        }

        let nextIndex = max(0, min(visibleItems.count - 1, currentIndex + offset))
        return visibleItems[nextIndex]
    }

    private func handlePreviewHover(_ item: RepositoryFileItem, isHovering: Bool) {
        if isHovering {
            hoveredPreviewFileID = item.id
            return
        }

        if hoveredPreviewFileID == item.id {
            hoveredPreviewFileID = nil
        }
    }

    private func ignorePath(for item: RepositoryFileItem) {
        runIgnoreAction(.exactPath(item.relativePath, isDirectory: item.kind == .directory), for: item)
    }

    private func ignoreFileName(for item: RepositoryFileItem) {
        runIgnoreAction(.fileName(item.displayName), for: item)
    }

    private func ignoreDirectory(_ directory: RepositoryIgnoreDirectoryOption, for item: RepositoryFileItem) {
        runIgnoreAction(.directory(directory.relativePath), for: item)
    }

    private func markAsSkipped(_ item: RepositoryFileItem) {
        guard item.canMarkAsSkipped else { return }
        runSkipWorktreeAction(
            title: "更新不提交文件失败",
            for: item
        ) { repository in
            try await skipWorktreeService.markSkipped(item, in: repository)
        }
    }

    private func removeFromSkipped(_ item: RepositoryFileItem) {
        guard item.canRemoveFromSkipped else { return }
        runSkipWorktreeAction(
            title: "移出不提交文件失败",
            for: item
        ) { repository in
            try await skipWorktreeService.removeSkipped(item, in: repository)
        }
    }

    private func runIgnoreAction(_ target: GitIgnoreRuleTarget, for item: RepositoryFileItem) {
        guard let repository = selectedRepository else { return }

        selectFile(item)

        Task {
            do {
                try await gitIgnoreWriter.append(target, to: repository)
                await MainActor.run {
                    statusStore.refreshCurrentRepository()
                }
            } catch {
                await MainActor.run {
                    repositoryFileActionAlert = RepositoryFileActionAlert(
                        title: "更新 .gitignore 失败",
                        message: GitCommandError.describe(error)
                    )
                }
            }
        }
    }

    private func runSkipWorktreeAction(
        title: String,
        for item: RepositoryFileItem,
        operation: @escaping (GitRepository) async throws -> Void
    ) {
        guard let repository = selectedRepository else { return }

        selectFile(item)

        Task {
            do {
                try await operation(repository)
                await MainActor.run {
                    statusStore.refreshCurrentRepository()
                }
            } catch {
                await MainActor.run {
                    repositoryFileActionAlert = RepositoryFileActionAlert(
                        title: title,
                        message: GitCommandError.describe(error)
                    )
                }
            }
        }
    }

    private func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    private func runCommitAction(_ action: GitCommitAction) {
        guard
            !isRunningCommitAction,
            let repository = selectedRepository,
            let snapshot = statusStore.snapshot
        else {
            return
        }

        let request = GitCommitRequest(
            repository: repository,
            message: commitMessage,
            changedItems: snapshot.changedFiles,
            action: action
        )

        isRunningCommitAction = true

        Task {
            do {
                let result = try await commitService.run(request)
                await MainActor.run {
                    isRunningCommitAction = false
                    commitMessage = ""
                    statusStore.refreshCurrentRepository()

                    if let pushErrorMessage = result.pushErrorMessage {
                        commitAlert = CommitAlert(
                            title: "推送失败",
                            message: "本地 commit 已完成，但推送远端失败：\(pushErrorMessage)"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isRunningCommitAction = false
                    commitAlert = CommitAlert(
                        title: "提交失败",
                        message: GitCommandError.describe(error)
                    )
                }
            }
        }
    }

    private func reconcileFileSelection(with fileIDs: [RepositoryFileItem.ID]) {
        guard selectedRepository != nil else {
            selectedFileIDs = []
            return
        }

        let validFileIDs = Set(fileIDs)
        selectedFileIDs = selectedFileIDs.intersection(validFileIDs)

        if let fileSelectionAnchorID, !validFileIDs.contains(fileSelectionAnchorID) {
            self.fileSelectionAnchorID = nil
        }

        if selectedFileIDs.isEmpty {
            fileSelectionAnchorID = nil
        }
    }

    private func reconcileHoveredPreview(with fileIDs: [RepositoryFileItem.ID]) {
        guard
            let hoveredPreviewFileID,
            selectedRepository != nil
        else {
            self.hoveredPreviewFileID = nil
            return
        }

        if !fileIDs.contains(hoveredPreviewFileID) {
            self.hoveredPreviewFileID = nil
        }
    }

    private func isExcludedFromDefaultCommit(_ item: RepositoryFileItem) -> Bool {
        (item.path as NSString).lastPathComponent == ".gitignore"
    }
}

#Preview {
    ContentView(
        llmSettingsStore: LLMSettingsStore(),
        aiCommitDebugStore: AICommitDebugStore()
    )
}

private struct SplitViewInitialDividerPositioner: NSViewRepresentable {
    let position: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.didApplyInitialPosition else { return }

        Task { @MainActor [weak nsView] in
            guard let nsView else { return }
            guard let splitView = enclosingSplitView(from: nsView) else { return }

            splitView.setPosition(position, ofDividerAt: 0)
            context.coordinator.didApplyInitialPosition = true
        }
    }

    private func enclosingSplitView(from view: NSView) -> NSSplitView? {
        var currentView: NSView? = view

        while let candidate = currentView?.superview {
            if let splitView = candidate as? NSSplitView {
                return splitView
            }
            currentView = candidate
        }

        return nil
    }

    final class Coordinator {
        var didApplyInitialPosition = false
    }
}

private struct WindowTitleBarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor [weak nsView] in
            guard let window = nsView?.window else { return }
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .visible
            applyWhiteTitle(in: window)
        }
    }

    private func applyWhiteTitle(in window: NSWindow) {
        guard let themeFrame = window.contentView?.superview else { return }

        for titleField in titleTextFields(in: themeFrame, matching: window.title) {
            titleField.textColor = .white
        }
    }

    private func titleTextFields(in root: NSView, matching title: String) -> [NSTextField] {
        var fields: [NSTextField] = []

        if let textField = root as? NSTextField, textField.stringValue == title {
            fields.append(textField)
        }

        for subview in root.subviews {
            fields.append(contentsOf: titleTextFields(in: subview, matching: title))
        }

        return fields
    }
}
