import AppKit
import SwiftUI

struct RepositoryFilePanel: View {
    private enum Layout {
        static let stackSpacing: CGFloat = 6
        static let contentIndent: CGFloat = 18
        static let sectionContentSpacing: CGFloat = 4
        static let subgroupSpacing: CGFloat = 6
        static let subgroupContentIndent: CGFloat = 12
        static let fileRowSpacing: CGFloat = 0
    }

    let repository: GitRepository?
    let snapshot: RepositoryFileSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    let expandedSections: Set<RepositoryFileSection>
    let selectedFileIDs: Set<RepositoryFileItem.ID>
    let selectionAnchorID: RepositoryFileItem.ID?
    let onToggleSection: (RepositoryFileSection) -> Void
    let onRefresh: () -> Void
    let onActivatePanel: () -> Void
    let onSelectFiles: (Set<RepositoryFileItem.ID>, RepositoryFileItem.ID?) -> Void
    let onSelectFile: (RepositoryFileItem) -> Void
    let onHoverFile: (RepositoryFileItem, Bool) -> Void
    let onIgnorePath: (RepositoryFileItem) -> Void
    let onIgnoreFileName: (RepositoryFileItem) -> Void
    let onIgnoreDirectory: (RepositoryIgnoreDirectoryOption, RepositoryFileItem) -> Void
    let onMarkAsSkipped: (RepositoryFileItem) -> Void
    let onRemoveFromSkipped: (RepositoryFileItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            Divider()

            Group {
                if repository == nil {
                    ContentUnavailableView(
                        "先选择一个仓库",
                        systemImage: "shippingbox",
                        description: Text("选中左侧仓库后，这里会读取文件状态。")
                    )
                } else if let errorMessage {
                    ContentUnavailableView(
                        "读取 Git 状态失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let snapshot {
                    if snapshot.isEmpty {
                        ContentUnavailableView(
                            "当前很干净",
                            systemImage: "checkmark.circle",
                            description: Text("没有更改、skip-worktree 或忽略文件。")
                        )
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Layout.stackSpacing) {
                                ForEach(RepositoryFileSection.allCases) { section in
                                    sectionBlock(
                                        for: section,
                                        items: snapshot.files(in: section),
                                        repositoryPath: snapshot.repositoryPath
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .background(Color.white)
                    }
                } else {
                    ProgressView("正在读取 Git 文件状态...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            if let snapshot {
                Text(summaryText(for: snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if repository != nil && isLoading {
                Text("正在读取更改文件、skip-worktree 和忽略文件。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(repository == nil || isLoading)
            .help("重新读取当前仓库状态")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func sectionBlock(
        for section: RepositoryFileSection,
        items: [RepositoryFileItem],
        repositoryPath: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.sectionContentSpacing) {
            RepositoryFileSectionHeaderRow(
                section: section,
                itemCount: items.count,
                isExpanded: expandedSections.contains(section),
                onToggleSection: { onToggleSection(section) }
            )

            if expandedSections.contains(section) {
                VStack(alignment: .leading, spacing: Layout.sectionContentSpacing) {
                    if items.isEmpty {
                        Text(section.emptyDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        if let subgroups = RepositoryFileSubgroup.makeSmartGroups(from: items) {
                            VStack(alignment: .leading, spacing: Layout.subgroupSpacing) {
                                ForEach(subgroups) { subgroup in
                                    subgroupBlock(
                                        subgroup,
                                        repositoryPath: repositoryPath
                                    )
                                }
                            }
                        } else {
                            fileRows(
                                items,
                                repositoryPath: repositoryPath,
                                subgroupPath: nil
                            )
                        }
                    }
                }
                .padding(.leading, Layout.contentIndent)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }
        }
        .animation(.easeInOut(duration: 0.16), value: expandedSections.contains(section))
    }

    private func summaryText(for snapshot: RepositoryFileSnapshot) -> String {
        [
            "\(snapshot.changedFiles.count) 个更改",
            "\(snapshot.skippedFiles.count) 个不提交",
            "\(snapshot.ignoredFiles.count) 个忽略"
        ]
        .joined(separator: "•")
    }

    @ViewBuilder
    private func subgroupBlock(
        _ subgroup: RepositoryFileSubgroup,
        repositoryPath: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.sectionContentSpacing) {
            RepositoryFileSubgroupHeaderRow(subgroup: subgroup)

            fileRows(
                subgroup.items,
                repositoryPath: repositoryPath,
                subgroupPath: subgroup.directoryPath
            )
            .padding(.leading, Layout.subgroupContentIndent)
        }
    }

    @ViewBuilder
    private func fileRows(
        _ items: [RepositoryFileItem],
        repositoryPath: String,
        subgroupPath: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.fileRowSpacing) {
            ForEach(items) { item in
                RepositoryFileInteractiveRow(
                    item: item,
                    repositoryPath: repositoryPath,
                    subgroupPath: subgroupPath,
                    isSelected: selectedFileIDs.contains(item.id),
                    onActivatePanel: onActivatePanel,
                    onActivate: { handleItemActivation($0, selectionScope: items) },
                    onHoverChange: onHoverFile,
                    onIgnorePath: onIgnorePath,
                    onIgnoreFileName: onIgnoreFileName,
                    onIgnoreDirectory: onIgnoreDirectory,
                    onMarkAsSkipped: onMarkAsSkipped,
                    onRemoveFromSkipped: onRemoveFromSkipped
                )
            }
        }
    }

    private func handleItemActivation(
        _ item: RepositoryFileItem,
        selectionScope: [RepositoryFileItem]
    ) {
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let isCommandPressed = modifiers.contains(.command)
        let isShiftPressed = modifiers.contains(.shift)

        if isShiftPressed {
            let nextSelection = makeRangeSelection(
                towards: item,
                within: selectionScope,
                isAdditive: isCommandPressed
            )
            onSelectFiles(nextSelection, selectionAnchorID ?? item.id)
            return
        }

        if isCommandPressed {
            var nextSelection = selectedFileIDs

            if nextSelection.contains(item.id) {
                nextSelection.remove(item.id)
            } else {
                nextSelection.insert(item.id)
            }

            onSelectFiles(nextSelection, item.id)
            return
        }

        onSelectFile(item)
    }

    private func makeRangeSelection(
        towards item: RepositoryFileItem,
        within selectionScope: [RepositoryFileItem],
        isAdditive: Bool
    ) -> Set<RepositoryFileItem.ID> {
        let orderedScopedFileIDs = selectionScope.map(\.id)

        guard let targetIndex = orderedScopedFileIDs.firstIndex(of: item.id) else {
            return fallbackSelection(for: item, isAdditive: isAdditive)
        }

        let anchorID = selectionAnchorID ?? item.id

        guard let anchorIndex = orderedScopedFileIDs.firstIndex(of: anchorID) else {
            return fallbackSelection(for: item, isAdditive: isAdditive)
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        let rangeSelection = Set(orderedScopedFileIDs[lowerBound...upperBound])

        if isAdditive {
            return selectedFileIDs.union(rangeSelection)
        }

        return rangeSelection
    }

    private func fallbackSelection(
        for item: RepositoryFileItem,
        isAdditive: Bool
    ) -> Set<RepositoryFileItem.ID> {
        if isAdditive {
            return selectedFileIDs.union([item.id])
        }

        return [item.id]
    }
}

private struct RepositoryFileSectionHeaderRow: View {
    let section: RepositoryFileSection
    let itemCount: Int
    let isExpanded: Bool
    let onToggleSection: () -> Void

    var body: some View {
        Button(action: onToggleSection) {
            HStack(spacing: 8) {
                Image(systemName: section.iconName)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14)

                Text(section.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(itemCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.16), value: isExpanded)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlColor).opacity(0.45))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RepositoryFileSubgroupHeaderRow: View {
    let subgroup: RepositoryFileSubgroup

    var body: some View {
        HStack(spacing: 8) {
            Text(subgroup.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(subgroup.items.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(0.22))
        )
    }
}

private struct RepositoryFileInteractiveRow: View {
    let item: RepositoryFileItem
    let repositoryPath: String
    let subgroupPath: String?
    let isSelected: Bool
    let onActivatePanel: () -> Void
    let onActivate: (RepositoryFileItem) -> Void
    let onHoverChange: (RepositoryFileItem, Bool) -> Void
    let onIgnorePath: (RepositoryFileItem) -> Void
    let onIgnoreFileName: (RepositoryFileItem) -> Void
    let onIgnoreDirectory: (RepositoryIgnoreDirectoryOption, RepositoryFileItem) -> Void
    let onMarkAsSkipped: (RepositoryFileItem) -> Void
    let onRemoveFromSkipped: (RepositoryFileItem) -> Void

    var body: some View {
        RepositoryFileRow(
            item: item,
            subgroupPath: subgroupPath,
            isSelected: isSelected
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onActivatePanel()
            onActivate(item)
        }
        .onHover { isHovering in
            onHoverChange(item, isHovering)
        }
        .contextMenu {
            Button("复制文件名：\(item.displayName)") {
                copyToPasteboard(item.displayName)
            }

            let absolutePath = fullPath(for: item)
            let absolutePathMenuTitle = condensedPathForMenu(absolutePath)

            Button("复制绝对路径：\(absolutePathMenuTitle)") {
                copyToPasteboard(absolutePath)
            }

            if item.isUntracked || item.canMarkAsSkipped || item.canRemoveFromSkipped {
                Divider()
            }

            if item.isUntracked {
                Button("忽略 \(item.relativePath) 的版本管理") {
                    onIgnorePath(item)
                }

                Button("忽略文件名为 \(item.displayName) 的版本管理") {
                    onIgnoreFileName(item)
                }

                Menu("忽略所在文件夹的版本管理") {
                    if item.directoryIgnoreOptions.isEmpty {
                        Button("文件位于仓库根目录，没有可忽略的上级目录") {}
                            .disabled(true)
                    } else {
                        ForEach(item.directoryIgnoreOptions) { directory in
                            Button(directory.relativePath) {
                                onIgnoreDirectory(directory, item)
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

    private func fullPath(for item: RepositoryFileItem) -> String {
        URL(fileURLWithPath: repositoryPath)
            .appendingPathComponent(item.relativePath)
            .path
    }

    private func condensedPathForMenu(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents

        guard components.count > 4, components.first == "/" else {
            return path
        }

        return "/\(components[1])/.../\(components.last ?? path)"
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct RepositoryFileRow: View {
    let item: RepositoryFileItem
    let subgroupPath: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.iconName)
                .font(.system(size: 12))
                .foregroundStyle(rowAccentColor)
                .frame(width: 14)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .strikethrough(item.isDeleted, color: Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .layoutPriority(1)

                if let parentPathDisplay = item.parentPathDisplay(relativeTo: subgroupPath) {
                    Text(parentPathDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.white)
        )
        .help(item.relativePath)
    }

    private var rowAccentColor: Color {
        isSelected ? Color.accentColor : .secondary
    }
}
