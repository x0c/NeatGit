import SwiftUI

struct RepositoryPreviewPane: View {
    let repository: GitRepository?
    let selectedFiles: [RepositoryFileItem]
    // Observe hover here so it does not redraw the rest of the workspace.
    let selection: WorkspaceSelectionStore
    let snapshot: RepositoryFileSnapshot?
    let cacheRevision: Int
    let onFileExpansion: (RepositoryFileItem, Bool) -> Void

    @State private var diffStore = RepositoryDiffStore()
    @State private var diffLayout: NativeDiffLayout = .sideBySide
    @State private var appliedSelectionSignature: String?

    private var hasCurrentSelection: Bool { appliedSelectionSignature == selectionSignature }
    private var changedFiles: [RepositoryFileItem] { snapshot?.changedFiles ?? [] }

    private var displayedDocument: RepositoryDiffDocument? {
        guard hasCurrentSelection, let document = diffStore.displayedDocument,
              document.repositoryPath == repository?.path,
              selectedFiles.count == 1, document.filePath == selectedFiles.first?.path else { return nil }
        return document
    }

    var body: some View {
        previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top, spacing: 0) { previewHeader }
            .background(Theme.Palette.diffCanvas)
            .task(id: selectionSignature) {
                diffStore.select(repository: repository, selectedFiles: selectedFiles, cacheRevision: cacheRevision)
                appliedSelectionSignature = selectionSignature
            }
            .task(id: hoverPrefetchSignature) {
                diffStore.scheduleHoverPrefetch(repository: repository, hoveredFile: hoveredFile, cacheRevision: cacheRevision)
            }
    }

    @ViewBuilder
    private var previewContent: some View {
        if repository == nil {
            ContentUnavailableView("选择仓库", systemImage: "folder")
        } else if snapshot == nil {
            Color.clear
        } else if hasCurrentSelection, selectedFiles.count == 1, selectedFiles.first?.section != .changed {
            ContentUnavailableView(diffStore.messageTitle, systemImage: "doc.text.magnifyingglass")
        } else if changedFiles.isEmpty {
            ContentUnavailableView("没有文件更改", systemImage: "checkmark.circle")
        } else {
            RepositoryChangedFileList(
                files: changedFiles,
                focusedFileID: selectedFiles.count == 1 ? selectedFiles.first?.id : nil,
                document: displayedDocument,
                layout: diffLayout,
                showChangesOnly: diffStore.showChangesOnly,
                isLoading: !hasCurrentSelection || diffStore.isLoading,
                showsPlaceholder: hasCurrentSelection && diffStore.showsPlaceholder,
                placeholderTitle: diffStore.messageTitle,
                placeholderBody: diffStore.messageBody,
                onFileExpansion: onFileExpansion
            )
        }
    }

    private var previewHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("差异").font(.headline)
            Spacer(minLength: Theme.Spacing.sm)

            if hasCurrentSelection {
                if diffStore.availableModes.count > 1 {
                    Picker("对比版本", selection: modeBinding) {
                        ForEach(diffStore.availableModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("diff-mode")
                } else if !diffStore.showsPlaceholder {
                    Text(diffStore.headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if diffStore.showsVisibilityToggle {
                    Toggle("只看变更", isOn: changesOnlyBinding)
                        .toggleStyle(.button)
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
        .controlSize(.small)
        .frame(minHeight: Theme.Workspace.headerHeight)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var modeBinding: Binding<RepositoryDiffMode> {
        Binding(get: { diffStore.activeMode }, set: { diffStore.selectMode($0) })
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
            set: { value in
                if value != diffStore.showChangesOnly { diffStore.toggleShowChangesOnly() }
            }
        )
    }

    private var selectionSignature: String {
        let selectedFileSignature = selectedFiles.map(\.id).joined(separator: "|")
        return "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(selectedFileSignature)"
    }

    private var hoveredFile: RepositoryFileItem? { selection.hoveredFile(in: snapshot) }

    private var hoverPrefetchSignature: String {
        "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(hoveredFile?.id ?? "no-hover")"
    }
}

// The list shows every changed file, but only the expanded file loads a diff.
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
    let onFileExpansion: (RepositoryFileItem, Bool) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
                            onExpansion: { onFileExpansion(item, $0) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
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
    let onExpansion: @MainActor (Bool) -> Void

    @ScaledMetric(relativeTo: .callout) private var rowHeight = Theme.Workspace.disclosureRowHeight

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isFocused }, set: onExpansion)) {
            focusedContent
        } label: {
            Button { onExpansion(!isFocused) } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    GitStatusBadge(style: item.statusStyle)
                    Text(item.displayName)
                        .font(.callout.weight(isFocused ? .semibold : .regular))
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let parentPath = item.parentPath {
                        Text(parentPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .frame(minHeight: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.path)
            .accessibilityLabel("\(item.displayName)，\(item.statusStyle.label)")
            .accessibilityIdentifier("diff-file-\(item.id)")
            .accessibilityValue(isFocused ? "已展开" : "已折叠")
        }
        Divider()
    }

    @ViewBuilder
    private var focusedContent: some View {
        if showsPlaceholder {
            ContentUnavailableView(
                placeholderTitle,
                systemImage: "doc.text.magnifyingglass",
                description: placeholderBody.isEmpty ? nil : Text(placeholderBody)
            )
            .frame(maxWidth: .infinity)
        } else if let document {
            NativeDiffView(document: document, layout: layout, showChangesOnly: showChangesOnly)
                .frame(height: diffHeight(for: document))
                .accessibilityIdentifier("file-diff-preview")
        } else if isLoading {
            ProgressView("读取差异")
                .controlSize(.small)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffHeight(for document: RepositoryDiffDocument) -> CGFloat {
        min(640, max(112, CGFloat(document.rows.count) * 22 + 32))
    }
}
