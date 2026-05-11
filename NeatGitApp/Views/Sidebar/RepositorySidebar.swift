import SwiftUI

struct RepositorySidebar: View {
    private enum Layout {
        static let minWidth: CGFloat = 260
        static let idealWidth: CGFloat = 340
        static let groupSpacing: CGFloat = 4
        static let listSpacing: CGFloat = 5
    }

    let groups: [RepositoryGroup]
    let isScanning: Bool
    let starredRepositoryPaths: Set<GitRepository.ID>
    @Binding var selectionPath: GitRepository.ID?
    @Binding var expandedGroupID: RepositoryGroup.ID?
    let onToggleGroup: (RepositoryGroup.ID) -> Void
    let onToggleRepositoryStar: (GitRepository) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.listSpacing) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Layout.groupSpacing) {
                            Button {
                                onToggleGroup(group.id)
                            } label: {
                                RepositoryGroupRow(
                                    group: group,
                                    isExpanded: expandedGroupID == group.id
                                )
                            }
                            .buttonStyle(.plain)

                            if expandedGroupID == group.id {
                                VStack(alignment: .leading, spacing: Layout.groupSpacing) {
                                    ForEach(group.repositories) { repository in
                                        RepositoryRow(
                                            repository: repository,
                                            isSelected: selectionPath == repository.id,
                                            isStarred: starredRepositoryPaths.contains(repository.id),
                                            onSelect: {
                                                selectionPath = repository.id
                                            },
                                            onToggleStar: {
                                                withAnimation(.easeInOut(duration: 0.16)) {
                                                    onToggleRepositoryStar(repository)
                                                }
                                            }
                                        )
                                    }
                                }
                                .padding(.leading, 20)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)
                                    )
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.white)
        }
        .background(Color.white)
        .frame(minWidth: Layout.minWidth, idealWidth: Layout.idealWidth, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: Layout.minWidth, ideal: Layout.idealWidth)
        .toolbar(removing: .sidebarToggle)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    "暂无项目",
                    systemImage: "folder.badge.questionmark",
                    description: Text(isScanning ? "正在扫描..." : "等待首次自动扫描完成")
                )
            }
        }
    }
}

private struct RepositoryGroupRow: View {
    private enum Layout {
        static let horizontalPadding: CGFloat = 9
        static let iconWidth: CGFloat = 16
        static let rowMinHeight: CGFloat = 31
    }

    let group: RepositoryGroup
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Layout.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.repositories.count) 个项目")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Layout.rowMinHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(0.6))
        )
        .contentShape(Rectangle())
    }
}

private struct RepositoryRow: View {
    private enum Layout {
        static let horizontalPadding: CGFloat = 9
        static let iconWidth: CGFloat = 16
        static let starButtonSize: CGFloat = 16
        static let rowMinHeight: CGFloat = 27
    }

    let repository: GitRepository
    let isSelected: Bool
    let isStarred: Bool
    let onSelect: () -> Void
    let onToggleStar: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: Layout.iconWidth)

                    Text(repository.name)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleStar) {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        isStarred
                            ? AnyShapeStyle(Color.yellow)
                            : AnyShapeStyle(Color(nsColor: .tertiaryLabelColor))
                    )
                    .frame(width: Layout.starButtonSize, height: Layout.starButtonSize)
            }
            .buttonStyle(.plain)
            .help(isStarred ? "取消收藏" : "收藏项目")
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Layout.rowMinHeight, alignment: .leading)
        .background(selectionBackground)
        .contentShape(Rectangle())
    }
}

private extension RepositoryRow {
    @ViewBuilder
    var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.clear)
        }
    }
}
