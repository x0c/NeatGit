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
            HStack {
                if let snapshot {
                    if let errorMessage {
                        Label("刷新失败：\(errorMessage)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(errorMessage)
                    } else {
                        Text(summaryText(for: snapshot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("文件更改")
                        .font(.headline)
                }
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func fileList(_ snapshot: RepositoryFileSnapshot) -> some View {
        List(selection: $selectedFileIDs) {
            ForEach(RepositoryFileSection.allCases) { section in
                DisclosureGroup(isExpanded: expansionBinding(for: section)) {
                    sectionContents(snapshot.files(in: section), repositoryPath: snapshot.repositoryPath, section: section)
                } label: {
                    Label {
                        HStack {
                            Text(section.title)
                            Spacer(minLength: 4)
                            Text(snapshot.files(in: section).count, format: .number)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.weight(.semibold))
                    } icon: {
                        Image(systemName: section.iconName)
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
        _ items: [RepositoryFileItem],
        repositoryPath: String,
        section: RepositoryFileSection
    ) -> some View {
        if items.isEmpty {
            Text(section.emptyDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        } else if let subgroups = RepositoryFileSubgroup.makeSmartGroups(from: items) {
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

                withAnimation(.easeInOut(duration: 0.16)) {
                    expandedSections = isExpanded ? [section] : []
                }
            }
        )
    }

    private func summaryText(for snapshot: RepositoryFileSnapshot) -> String {
        "\(snapshot.changedFiles.count) 个更改 · \(snapshot.skippedFiles.count) 个不提交 · \(snapshot.ignoredFiles.count) 个忽略"
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
        .help(item.relativePath)
        .accessibilityIdentifier("file-\(item.id)")
        .onHover { onHoverChange(item, $0) }
        .contextMenu {
            Button("复制文件名：\(item.displayName)") {
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

            if item.isUntracked {
                Button("忽略 \(item.relativePath) 的版本管理") {
                    onIgnore(.exactPath(item.relativePath, isDirectory: item.kind == .directory), item)
                }
                Button("忽略文件名为 \(item.displayName) 的版本管理") {
                    onIgnore(.fileName(item.displayName), item)
                }
                Menu("忽略所在文件夹的版本管理") {
                    if item.directoryIgnoreOptions.isEmpty {
                        Button("文件位于仓库根目录，没有可忽略的上级目录") {}
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
                Button("将 \(item.displayName) 标记为不提交的文件") {
                    onMarkAsSkipped(item)
                }
            }
            if item.canRemoveFromSkipped {
                Button("将 \(item.displayName) 移出不提交的文件") {
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
