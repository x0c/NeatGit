import SwiftUI

/// 主窗口编排层。
///
/// 这里只做三件事：组装三栏骨架、把 store 的状态接到子视图、把用户意图转发给 store。
/// Git 调用、LLM 调用、异步错误处理、选择态一致性规则都在 `Stores/` 里，
/// 视图不再直接持有服务对象，也不再出现 `Task { ... MainActor.run { ... } }` 样板。
struct ContentView: View {
    let llmSettingsStore: LLMSettingsStore
    let aiCommitDebugStore: AICommitDebugStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var repositoryStore = RepositoryStore()
    @State private var statusStore = RepositoryStatusStore()
    @State private var selection = WorkspaceSelectionStore()
    @State private var fileActionStore = RepositoryFileActionStore()
    @State private var commitStore: CommitWorkflowStore

    init(
        llmSettingsStore: LLMSettingsStore,
        aiCommitDebugStore: AICommitDebugStore
    ) {
        self.llmSettingsStore = llmSettingsStore
        self.aiCommitDebugStore = aiCommitDebugStore
        _commitStore = State(
            initialValue: CommitWorkflowStore(
                llmSettingsStore: llmSettingsStore,
                generationService: CommitMessageGenerationService(debugStore: aiCommitDebugStore)
            )
        )
    }

    var body: some View {
        // 这里刻意分三层写（骨架 / 生命周期 / 弹窗）。
        // 全部链在一个表达式上会让类型检查超时，
        // 实测报 「unable to type-check this expression in reasonable time」。
        observedWorkspace
            .modifier(WorkspaceAlerts(fileActionStore: fileActionStore, commitStore: commitStore))
    }

    /// 骨架 + 生命周期：首次扑全、切仓库加载、回到前台刷新、列表变化校正选择态。
    private var observedWorkspace: some View {
        workspace
            .task {
                guard repositoryStore.repositories.isEmpty else { return }
                repositoryStore.refresh()
            }
            .task(id: selection.selectedRepositoryID) {
                statusStore.load(for: selectedRepository)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !commitStore.isBusy else { return }
                statusStore.refreshCurrentRepository()
            }
            .onChange(of: repositoryStore.repositories) { _, repositories in
                selection.reconcile(with: repositories, groups: repositoryGroups)
            }
            .onChange(of: statusStore.snapshot?.allFiles.map(\.id) ?? []) { _, fileIDs in
                selection.reconcileFiles(with: fileIDs)
            }
    }

    // MARK: - 派生状态

    private var repositoryGroups: [RepositoryGroup] {
        RepositoryGroup.makeGroups(
            from: repositoryStore.repositories,
            starredRepositoryPaths: repositoryStore.starredRepositoryPaths
        )
    }

    private var selectedRepository: GitRepository? {
        selection.repository(in: repositoryStore.repositories)
    }

    // MARK: - 骨架

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .disabled(commitStore.isBusy)
        } content: {
            filePane
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
        } detail: {
            RepositoryPreviewPane(
                repository: selectedRepository,
                selectedFiles: selection.selectedFiles(in: statusStore.snapshot),
                hoveredFile: selection.hoveredFile(in: statusStore.snapshot),
                cacheRevision: statusStore.snapshotRevision
            )
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(selectedRepository?.name ?? "NeatGit")
        .frame(minWidth: 960, minHeight: 600)
        .toolbar { workspaceToolbar }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("刷新文件", systemImage: "arrow.clockwise") {
                statusStore.refreshCurrentRepository()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(selectedRepository == nil || statusStore.isLoading || commitStore.isBusy)
            .help("重新读取当前仓库状态")
            .accessibilityIdentifier("refresh-repository")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Menu("项目操作", systemImage: "ellipsis.circle") {
                Button("重新扫描项目", systemImage: "folder.badge.arrow.up") {
                    repositoryStore.refresh()
                }
                .disabled(repositoryStore.isScanning || commitStore.isBusy)

                Divider()
                SettingsLink()
                Button("AI 调试", systemImage: "ladybug", action: openCommitDebugWindow)
            }
            .accessibilityIdentifier("repository-actions")
        }
    }

    private var sidebar: some View {
        RepositorySidebar(
            groups: repositoryGroups,
            isScanning: repositoryStore.isScanning,
            starredRepositoryPaths: repositoryStore.starredRepositoryPaths,
            selectionPath: Binding(
                get: { selection.selectedRepositoryID },
                set: { selection.selectRepository($0, in: repositoryStore.repositories) }
            ),
            expandedGroupID: $selection.expandedGroupID,
            onToggleGroup: { groupID in
                withAnimation(Theme.disclosureAnimation) {
                    selection.toggleGroup(groupID)
                }
            },
            onToggleRepositoryStar: repositoryStore.toggleStar(for:),
            onPrefetchRepository: statusStore.prefetch(for:)
        )
    }

    private var filePane: some View {
        RepositoryFilePanel(
            repository: selectedRepository,
            snapshot: statusStore.snapshot,
            isLoading: statusStore.isLoading,
            errorMessage: statusStore.errorMessage,
            selectedFileIDs: $selection.selectedFileIDs,
            onRefresh: statusStore.refreshCurrentRepository,
            onHoverFile: selection.updateHover(_:isHovering:),
            onIgnore: handleIgnore(_:for:),
            onMarkAsSkipped: { item in
                runFileAction(for: item) { repository, onFinish in
                    fileActionStore.markAsSkipped(item, in: repository, onFinish: onFinish)
                }
            },
            onRemoveFromSkipped: { item in
                runFileAction(for: item) { repository, onFinish in
                    fileActionStore.removeFromSkipped(item, in: repository, onFinish: onFinish)
                }
            }
        )
        .disabled(commitStore.isRunningCommitAction)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            CommitComposerBar(
                repository: selectedRepository,
                commitMessage: $commitStore.commitMessage,
                isRunningCommitAction: commitStore.isRunningCommitAction,
                isGeneratingMessage: commitStore.isGeneratingMessage,
                statusMessage: commitStore.statusMessage(
                    repository: selectedRepository,
                    snapshot: statusStore.snapshot
                ),
                onOpenDebugWindow: openCommitDebugWindow,
                onGenerateMessage: {
                    commitStore.generateMessage(
                        for: selectedRepository,
                        snapshot: statusStore.snapshot
                    )
                },
                onCommitAndPush: { runCommit(.commitAndPush) },
                onCommitOnly: { runCommit(.commitOnly) }
            )
        }
    }

    // MARK: - 意图转发

    private func openCommitDebugWindow() {
        openWindow(id: AICommitDebugWindowView.windowID)
    }

    private func runCommit(_ action: GitCommitAction) {
        commitStore.commit(
            action,
            repository: selectedRepository,
            snapshot: statusStore.snapshot,
            onFinish: statusStore.refreshCurrentRepository
        )
    }

    private func handleIgnore(_ target: GitIgnoreRuleTarget, for item: RepositoryFileItem) {
        runFileAction(for: item) { repository, onFinish in
            fileActionStore.appendIgnoreRule(target, in: repository, onFinish: onFinish)
        }
    }

    /// 文件级操作统一入口：先把该行设为选中，再执行，完成后刷新状态。
    private func runFileAction(
        for item: RepositoryFileItem,
        operation: (GitRepository, @escaping () -> Void) -> Void
    ) {
        guard let repository = selectedRepository else { return }

        selection.selectFile(item)
        operation(repository, statusStore.refreshCurrentRepository)
    }
}

#Preview {
    ContentView(
        llmSettingsStore: LLMSettingsStore(),
        aiCommitDebugStore: AICommitDebugStore()
    )
}

/// 两个弹窗的挂载。
///
/// 抽成 `ViewModifier` 是为了把类型检查切成小块：
/// 两条 `alert(_:isPresented:presenting:)` 带双尾随闭包，跟在主链后面会把编译器拖到超时。
private struct WorkspaceAlerts: ViewModifier {
    @Bindable var fileActionStore: RepositoryFileActionStore
    @Bindable var commitStore: CommitWorkflowStore

    func body(content: Content) -> some View {
        content
            .alert(
                fileActionStore.alert?.title ?? "文件操作失败",
                isPresented: Binding(
                    get: { fileActionStore.alert != nil },
                    set: { if !$0 { fileActionStore.alert = nil } }
                ),
                presenting: fileActionStore.alert
            ) { _ in
                Button("知道了", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .alert(
                commitStore.alert?.title ?? "提交提示",
                isPresented: Binding(
                    get: { commitStore.alert != nil },
                    set: { if !$0 { commitStore.alert = nil } }
                ),
                presenting: commitStore.alert
            ) { _ in
                Button("知道了", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }
}
