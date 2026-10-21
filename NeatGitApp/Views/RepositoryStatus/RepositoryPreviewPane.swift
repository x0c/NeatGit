import SwiftUI

struct RepositoryPreviewPane: View {
    let repository: GitRepository?
    let selectedFiles: [RepositoryFileItem]
    let hoveredFile: RepositoryFileItem?
    let cacheRevision: Int

    @State private var diffStore = RepositoryDiffStore()

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
        ZStack {
            MonacoDiffView(
                payload: diffStore.payloadForDisplay,
                showChangesOnly: diffStore.showChangesOnly
            )
                .accessibilityIdentifier("file-diff-preview")

            if diffStore.showsPlaceholder {
                ContentUnavailableView(
                    diffStore.messageTitle,
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(diffStore.messageBody)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }

            if diffStore.isLoading {
                ProgressView("正在读取文件差异…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diffStore.headerTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(diffStore.headerTitle)

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

                    Spacer(minLength: 8)

                    if diffStore.showsVisibilityToggle {
                        Toggle("只看变更", isOn: changesOnlyBinding)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .help(diffStore.visibilityToggleTitle)
                            .accessibilityIdentifier("diff-changes-only")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modeBinding: Binding<RepositoryDiffMode> {
        Binding(
            get: { diffStore.activeMode },
            set: { diffStore.selectMode($0) }
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

    private var hoverPrefetchSignature: String {
        "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(hoveredFile?.id ?? "no-hover")"
    }
}
