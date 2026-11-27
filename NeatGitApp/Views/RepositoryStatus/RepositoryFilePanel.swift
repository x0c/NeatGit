import AppKit
import SwiftUI

struct RepositoryFilePanel: View {
    let repository: GitRepository?
    let snapshot: RepositoryFileSnapshot?
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
    @State private var showsErrorDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .callout) private var rowHeight = Theme.Workspace.rowHeight

    var body: some View {
        Group {
            if let snapshot {
                fileList(snapshot)
            } else if repository != nil && errorMessage == nil {
                loadingRows
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("文件").font(.headline)
                Spacer(minLength: 0)
                if errorMessage != nil {
                    Button(snapshot == nil ? "无法读取" : "无法刷新", systemImage: "exclamationmark.triangle") {
                        showsErrorDetails = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help("查看错误详情")
                }
            }
            .frame(minHeight: Theme.Workspace.headerHeight)
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .alert("无法读取文件状态", isPresented: $showsErrorDetails, presenting: errorMessage) { _ in
            Button("重试", action: onRefresh)
            Button("关闭", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    private var loadingRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RepositoryFileSection.allCases) { section in
                Label(section.title, systemImage: section.iconName)
                    .font(.callout)
                    .frame(minHeight: rowHeight)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fileList(_ snapshot: RepositoryFileSnapshot) -> some View {
        List(selection: $selectedFileIDs) {
            ForEach(RepositoryFileSection.allCases) { section in
                DisclosureGroup(isExpanded: expansionBinding(for: section)) {
                    sectionContents(snapshot, section: section)
                } label: {
                    Button {
                        expansionBinding(for: section).wrappedValue.toggle()
                    } label: {
                        Label {
                            HStack(spacing: Theme.Spacing.sm) {
                                Text(section.title).font(.callout.weight(.medium))
                                Spacer(minLength: 0)
                                Text(snapshot.files(in: section).count, format: .number)
                                    .font(Theme.Font.count)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: section.iconName).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("file-section-\(section.rawValue)")
                }
                .selectionDisabled()
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
        if let subgroups = snapshot.smartGroups(in: section) {
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
                    withAnimation(Theme.disclosureAnimation(reduceMotion: reduceMotion)) {
                        expandedSections = isExpanded ? [section] : []
                    }
                }
            }
        )
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

    @ScaledMetric(relativeTo: .callout) private var rowHeight = Theme.Workspace.rowHeight

    var body: some View {
        Label {
            HStack(spacing: Theme.Spacing.xs) {
                Text(item.displayName)
                    .font(.callout)
                    .strikethrough(item.isDeleted)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if let parentPath = item.parentPathDisplay(relativeTo: subgroupPath) {
                    Text(parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.head)
                }
            }
            .lineLimit(1)
        } icon: {
            GitStatusBadge(style: item.statusStyle)
        }
        .frame(minHeight: rowHeight)
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
