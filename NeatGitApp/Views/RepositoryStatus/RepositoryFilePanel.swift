import AppKit
import SwiftUI

struct RepositoryFilePanel: View {
    let repository: GitRepository?
    let snapshot: RepositoryFileSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    @Binding var selectedFileIDs: Set<RepositoryFileItem.ID>
    let onRefresh: () -> Void
    let onHoverFile: (RepositoryFileItem, Bool) -> Void
    let onIgnore: (GitIgnoreRuleTarget, RepositoryFileItem) -> Void
    let onMarkAsSkipped: (RepositoryFileItem) -> Void
    let onRemoveFromSkipped: (RepositoryFileItem) -> Void

    /// 展开的分区纯属本面板的展示形态，外部没有人读它，
    /// 放在这里自持比从主视图透传更贴合归属。始终只展开一组。
    @State private var expandedSections: Set<RepositoryFileSection> = [.changed]

    var body: some View {
        Group {
            // 有内容时优先展示内容（含过时缓存），读取失败只降级为顶部提示，
            // 避免后台刷新失败把整个列表清成错误页。
            if repository == nil {
                ContentUnavailableView(
                    "先选择一个仓库",
                    systemImage: "shippingbox",
                    description: Text("选中左侧仓库后，这里会读取文件状态。")
                )
            } else if let snapshot {
                if snapshot.isEmpty {
                    ContentUnavailableView(
                        "当前很干净",
                        systemImage: "checkmark.circle",
                        description: Text("没有更改、不提交或忽略的文件。")
                    )
                } else {
                    fileList(snapshot)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("读取 Git 状态失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重新读取", action: onRefresh)
                }
            } else {
                ProgressView("正在读取文件状态…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Label("文件更改", systemImage: "square.stack.3d.up")
                        .font(.headline)
                        .symbolRenderingMode(.hierarchical)

                    Spacer(minLength: Theme.Spacing.sm)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在读取文件状态")
                    }
                }

                if let snapshot {
                    if let errorMessage {
                        // 刷新失败降级为顶部提示（SWR）：快照内容保留可操作，
                        // 警示图标与主要正文避免失败被误认为普通摘要。
                        Label {
                            Text("刷新失败：\(errorMessage)")
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .help(errorMessage)
                    } else {
                        HStack(spacing: Theme.Spacing.xs) {
                            RepositorySummaryBadge(
                                count: snapshot.changedFiles.count,
                                title: "更改",
                                tint: Theme.Palette.accent
                            )
                            RepositorySummaryBadge(
                                count: snapshot.skippedFiles.count,
                                title: "不提交",
                                tint: .orange
                            )
                            RepositorySummaryBadge(
                                count: snapshot.ignoredFiles.count,
                                title: "忽略",
                                tint: .secondary
                            )
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func fileList(_ snapshot: RepositoryFileSnapshot) -> some View {
        List(selection: $selectedFileIDs) {
            ForEach(RepositoryFileSection.allCases) { section in
                DisclosureGroup(isExpanded: expansionBinding(for: section)) {
                    sectionContents(snapshot, section: section)
                } label: {
                    Label {
                        HStack {
                            Text(section.title)
                            Spacer(minLength: Theme.Spacing.xxs)
                            Text(snapshot.files(in: section).count, format: .number)
                                .font(Theme.Font.count)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Spacing.xs)
                                .padding(.vertical, Theme.Spacing.textStack)
                                .background(.quaternary, in: Capsule())
                        }
                        .font(.callout.weight(.semibold))
                    } icon: {
                        Image(systemName: section.iconName)
                            .foregroundStyle(tint(for: section))
                    }
                }
                .selectionDisabled()
                .accessibilityIdentifier("file-section-\(section.rawValue)")
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("repository-files")
    }

    @ViewBuilder
    private func sectionContents(
        _ snapshot: RepositoryFileSnapshot,
        section: RepositoryFileSection
    ) -> some View {
        let items = snapshot.files(in: section)
        let repositoryPath = snapshot.repositoryPath
        if items.isEmpty {
            Text(section.emptyDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        } else if let subgroups = snapshot.smartGroups(in: section) {
            ForEach(subgroups) { subgroup in
                Section {
                    fileRows(subgroup.items, repositoryPath: repositoryPath, subgroupPath: subgroup.directoryPath)
                } header: {
                    HStack {
                        Text(subgroup.title)
                        Spacer()
                        Text(subgroup.items.count, format: .number)
                    }
                    .font(.caption)
                    .help(subgroup.directoryPath)
                }
            }
        } else {
            fileRows(items, repositoryPath: repositoryPath, subgroupPath: nil)
        }
    }

    private func fileRows(
        _ items: [RepositoryFileItem],
        repositoryPath: String,
        subgroupPath: String?
    ) -> some View {
        ForEach(items) { item in
            RepositoryFileInteractiveRow(
                item: item,
                repositoryPath: repositoryPath,
                subgroupPath: subgroupPath,
                onHoverChange: onHoverFile,
                onIgnore: onIgnore,
                onMarkAsSkipped: onMarkAsSkipped,
                onRemoveFromSkipped: onRemoveFromSkipped
            )
            .tag(item.id)
            .selectionDisabled(false)
        }
    }

    private func expansionBinding(for section: RepositoryFileSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { isExpanded in
                guard isExpanded != expandedSections.contains(section) else { return }

                // 与 Theme.disclosureAnimation 共用同一 token，
                // 避免侧栏/中栏各自手写 duration 导致节奏不一致。
                InteractionProfiler.measure("文件分组.展开折叠") {
                    withAnimation(Theme.disclosureAnimation) {
                        expandedSections = isExpanded ? [section] : []
                    }
                }
            }
        )
    }

    private func tint(for section: RepositoryFileSection) -> some ShapeStyle {
        switch section {
        case .changed:
            return Theme.Palette.accent
        case .skipped:
            return Color.orange
        case .ignored:
            return Color.secondary
        }
    }
}

/// 顶栏摘要标签：数字、文字和语义色共同表达状态，不依赖颜色单独区分。
private struct RepositorySummaryBadge: View {
    let count: Int
    let title: String
    let tint: Color

    private var resolvedTint: Color {
        count == 0 ? .secondary : tint
    }

    var body: some View {
        Text("\(count) 个\(title)")
            .font(.caption.weight(.medium))
            .foregroundStyle(resolvedTint)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(resolvedTint.opacity(0.09), in: Capsule())
    }
}

private struct RepositoryFileInteractiveRow: View {
    let item: RepositoryFileItem
    let repositoryPath: String
    let subgroupPath: String?
    let onHoverChange: (RepositoryFileItem, Bool) -> Void
    let onIgnore: (GitIgnoreRuleTarget, RepositoryFileItem) -> Void
    let onMarkAsSkipped: (RepositoryFileItem) -> Void
    let onRemoveFromSkipped: (RepositoryFileItem) -> Void

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(item.isDeleted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let parentPath = item.parentPathDisplay(relativeTo: subgroupPath) {
                    Text(parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } icon: {
            GitStatusBadge(style: item.statusStyle)
        }
        .padding(.vertical, Theme.Spacing.textStack)
        .help(item.relativePath)
        .accessibilityIdentifier("file-\(item.id)")
        .accessibilityLabel("\(item.displayName)，\(item.statusStyle.label)")
        .onHover { onHoverChange(item, $0) }
        .contextMenu {
            Button("复制文件名") {
                copyToPasteboard(item.displayName)
            }

            let absolutePath = URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent(item.relativePath).path
            Button("复制绝对路径") {
                copyToPasteboard(absolutePath)
            }

            if item.isUntracked || item.canMarkAsSkipped || item.canRemoveFromSkipped {
                Divider()
            }

            // 忽略 / skip-worktree 都是可逆操作（改 .gitignore / 解标记即可恢复），
            // 按保护性摩擦规则不加二次确认；失败经 fileActionStore.alert 弹窗，
            // 不在这里吞错。
            if item.isUntracked {
                Button("忽略此路径") {
                    onIgnore(.exactPath(item.relativePath, isDirectory: item.kind == .directory), item)
                }
                Button("忽略所有同名文件“\(item.displayName)”") {
                    onIgnore(.fileName(item.displayName), item)
                }
                Menu("忽略所在文件夹") {
                    if item.directoryIgnoreOptions.isEmpty {
                        Button("位于仓库根目录，没有可忽略的上级目录") {}
                            .disabled(true)
                    } else {
                        ForEach(item.directoryIgnoreOptions) { directory in
                            Button(directory.relativePath) {
                                onIgnore(.directory(directory.relativePath), item)
                            }
                        }
                    }
                }
            }

            if item.canMarkAsSkipped {
                Button("标为不提交") {
                    onMarkAsSkipped(item)
                }
            }
            if item.canRemoveFromSkipped {
                Button("移出不提交") {
                    onRemoveFromSkipped(item)
                }
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
