import SwiftUI

struct RepositoryPreviewPane: View {
    let repository: GitRepository?
    let selectedFiles: [RepositoryFileItem]
    let changedFiles: [RepositoryFileItem]
    /// 悬停只在本视图内观察，避免鼠标划过文件行时刷新整个三栏骨架。
    let selection: WorkspaceSelectionStore
    let snapshot: RepositoryFileSnapshot?
    let cacheRevision: Int
    let onFocusFile: (RepositoryFileItem) -> Void

    @State private var diffStore = RepositoryDiffStore()
    @State private var diffLayout: NativeDiffLayout = .sideBySide

    var body: some View {
        previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top, spacing: 0) {
                previewHeader
            }
            .task(id: selectionSignature) {
                diffStore.select(
                    repository: repository,
                    selectedFiles: selectedFiles,
                    cacheRevision: cacheRevision
                )
            }
            .task(id: hoverPrefetchSignature) {
                diffStore.scheduleHoverPrefetch(
                    repository: repository,
                    hoveredFile: hoveredFile,
                    cacheRevision: cacheRevision
                )
            }
    }

    private var previewContent: some View {
        Group {
            if changedFiles.isEmpty {
                ContentUnavailableView(
                    diffStore.messageTitle,
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(diffStore.messageBody)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            } else {
                RepositoryChangedFileList(
                    files: changedFiles,
                    focusedFileID: selectedFiles.count == 1 ? selectedFiles.first?.id : nil,
                    document: diffStore.displayedDocument,
                    layout: diffLayout,
                    showChangesOnly: diffStore.showChangesOnly,
                    isLoading: diffStore.isLoading,
                    showsPlaceholder: diffStore.showsPlaceholder,
                    placeholderTitle: diffStore.messageTitle,
                    placeholderBody: diffStore.messageBody,
                    onFocusFile: onFocusFile
                )
            }
        }
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: changedFiles.isEmpty ? "doc.text.magnifyingglass" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        Theme.Palette.accent.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                    )

                Text(changedFiles.isEmpty ? diffStore.headerTitle : "全部变动（\(changedFiles.count)）")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(changedFiles.isEmpty ? diffStore.headerTitle : "全部变动（\(changedFiles.count)）")

                Spacer(minLength: 0)
            }

            HStack {
                // 占位态（空选/多选/失败）不渲染副标题行，避免出现只有
                // 通用副标题 + 空白 Spacer 的空行；说明由下方占位视图承担。
                // 加载态 showsPlaceholder 为 false，副标题正常保留。
                if diffStore.availableModes.count > 1
                    || diffStore.showsVisibilityToggle
                    || !diffStore.showsPlaceholder
                {
                    if diffStore.availableModes.count > 1 {
                        Picker("对比版本", selection: modeBinding) {
                            ForEach(diffStore.availableModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("diff-mode")
                    } else if !diffStore.showsPlaceholder {
                        // 占位态的说明由下方 ContentUnavailableView 承担，
                        // 头部不再重复通用的 headerSubtitle。
                        Text(diffStore.headerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    if diffStore.showsVisibilityToggle {
                        Toggle("只看变更", isOn: changesOnlyBinding)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .help(diffStore.visibilityToggleTitle)
                            .accessibilityIdentifier("diff-changes-only")

                        Picker("差异布局", selection: layoutBinding) {
                            ForEach(NativeDiffLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("diff-layout")
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var modeBinding: Binding<RepositoryDiffMode> {
        Binding(
            get: { diffStore.activeMode },
            set: { diffStore.selectMode($0) }
        )
    }

    private var layoutBinding: Binding<NativeDiffLayout> {
        Binding(
            get: { diffLayout },
            set: { layout in
                InteractionProfiler.measure("差异布局.点击处理", detail: "布局：\(layout.title)") {
                    diffLayout = layout
                }
            }
        )
    }

    private var changesOnlyBinding: Binding<Bool> {
        Binding(
            get: { diffStore.showChangesOnly },
            set: { showChangesOnly in
                if showChangesOnly != diffStore.showChangesOnly {
                    diffStore.toggleShowChangesOnly()
                }
            }
        )
    }

    private var selectionSignature: String {
        let selectedFileSignature = selectedFiles.map(\.id).joined(separator: "|")
        return "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(selectedFileSignature)"
    }

    private var hoveredFile: RepositoryFileItem? {
        selection.hoveredFile(in: snapshot)
    }

    private var hoverPrefetchSignature: String {
        "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(hoveredFile?.id ?? "no-hover")"
    }
}

/// 仓库级变动列表。数据层仍只读取当前文件，折叠行不负责预加载差异。
private struct RepositoryChangedFileList: View {
    let files: [RepositoryFileItem]
    let focusedFileID: RepositoryFileItem.ID?
    let document: RepositoryDiffDocument?
    let layout: NativeDiffLayout
    let showChangesOnly: Bool
    let isLoading: Bool
    let showsPlaceholder: Bool
    let placeholderTitle: String
    let placeholderBody: String
    let onFocusFile: (RepositoryFileItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if focusedFileID == nil {
                        Text("选择关注的文件以展开变动")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(Theme.Spacing.lg)
                    }

                    ForEach(files) { item in
                        RepositoryChangedFileDisclosure(
                            item: item,
                            isFocused: item.id == focusedFileID,
                            document: document,
                            layout: layout,
                            showChangesOnly: showChangesOnly,
                            isLoading: isLoading,
                            showsPlaceholder: showsPlaceholder,
                            placeholderTitle: placeholderTitle,
                            placeholderBody: placeholderBody,
                            onFocusFile: onFocusFile
                        )
                        .id(item.id)
                    }
                }
            }
            .accessibilityIdentifier("changed-file-diff-list")
            .task(id: focusedFileID) {
                guard let focusedFileID else { return }
                proxy.scrollTo(focusedFileID, anchor: .top)
            }
        }
    }
}

private struct RepositoryChangedFileDisclosure: View {
    let item: RepositoryFileItem
    let isFocused: Bool
    let document: RepositoryDiffDocument?
    let layout: NativeDiffLayout
    let showChangesOnly: Bool
    let isLoading: Bool
    let showsPlaceholder: Bool
    let placeholderTitle: String
    let placeholderBody: String
    let onFocusFile: (RepositoryFileItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onFocusFile(item)
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: isFocused ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    GitStatusBadge(style: item.statusStyle)

                    VStack(alignment: .leading, spacing: Theme.Spacing.textStack) {
                        Text(item.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let parentPath = item.parentPath {
                            Text(parentPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    if isFocused && isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在读取文件差异")
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isFocused ? Theme.Palette.accent.opacity(0.07) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diff-file-\(item.id)")
            .accessibilityValue(isFocused ? "已展开" : "已折叠")
            .accessibilityHint("查看此文件的变动")

            if isFocused {
                Divider()
                focusedContent
            }

            Divider()
        }
    }

    @ViewBuilder
    private var focusedContent: some View {
        if showsPlaceholder {
            ContentUnavailableView(
                placeholderTitle,
                systemImage: "doc.text.magnifyingglass",
                description: Text(placeholderBody)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
            .background(.background)
        } else if document == nil && isLoading {
            ProgressView("正在读取文件差异…")
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            NativeDiffView(
                document: document,
                layout: layout,
                showChangesOnly: showChangesOnly
            )
            .frame(height: diffHeight)
            .accessibilityIdentifier("file-diff-preview")
        }
    }

    /// 小文件不留下整屏空白，大文件限制在可视区域内继续滚动。
    private var diffHeight: CGFloat {
        let estimatedContentHeight = CGFloat(document?.rows.count ?? 0) * 22 + 32
        return min(640, max(240, estimatedContentHeight))
    }
}
