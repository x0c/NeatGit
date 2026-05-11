import SwiftUI

struct RepositoryPreviewPane: View {
    let repository: GitRepository?
    let selectedFiles: [RepositoryFileItem]
    let hoveredFile: RepositoryFileItem?
    let cacheRevision: Int

    @StateObject private var diffStore = RepositoryDiffStore()

    var body: some View {
        VStack(spacing: 0) {
            RepositoryPreviewHeader(
                title: headerTitle,
                subtitle: headerSubtitle,
                showsVisibilityToggle: diffStore.showsVisibilityToggle,
                visibilityToggleIsActive: diffStore.showChangesOnly,
                visibilityToggleTitle: diffStore.visibilityToggleTitle,
                visibilityToggleSystemImage: diffStore.visibilityToggleSystemImage,
                onToggleVisibility: diffStore.toggleShowChangesOnly
            )

            Divider()

            previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .background(Color.white)
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

    @ViewBuilder
    private var previewContent: some View {
        ZStack {
            MonacoDiffView(payload: diffStore.payloadForDisplay)

            if diffStore.showsPlaceholder {
                ContentUnavailableView(
                    diffStore.messageTitle,
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(diffStore.messageBody)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            }

            if diffStore.isLoading {
                ProgressView("正在生成文件 diff...")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var headerTitle: String {
        diffStore.headerTitle
    }

    private var headerSubtitle: String {
        diffStore.headerSubtitle
    }

    private var selectionSignature: String {
        let selectedFileSignature = selectedFiles.map(\.id).joined(separator: "|")
        return "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(selectedFileSignature)"
    }

    private var hoverPrefetchSignature: String {
        "\(repository?.id ?? "no-repository")::\(cacheRevision)::\(hoveredFile?.id ?? "no-hover")"
    }
}

private struct RepositoryPreviewHeader: View {
    let title: String
    let subtitle: String
    let showsVisibilityToggle: Bool
    let visibilityToggleIsActive: Bool
    let visibilityToggleTitle: String
    let visibilityToggleSystemImage: String
    let onToggleVisibility: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if showsVisibilityToggle {
                Button(action: onToggleVisibility) {
                    Image(systemName: visibilityToggleSystemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(visibilityToggleIsActive ? .primary : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(visibilityToggleTitle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
