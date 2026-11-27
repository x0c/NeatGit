import SwiftUI

struct RepositorySidebar: View {
    private enum Layout {
        static let minWidth: CGFloat = 240
        static let idealWidth: CGFloat = 300
    }

    let groups: [RepositoryGroup]
    let isScanning: Bool
    let starredRepositoryPaths: Set<GitRepository.ID>
    @Binding var selectionPath: GitRepository.ID?
    @Binding var expandedGroupID: RepositoryGroup.ID?
    let onToggleGroup: (RepositoryGroup.ID) -> Void
    let onToggleRepositoryStar: (GitRepository) -> Void
    /// 接收侧栏仓库行的进入 / 离开事件；由状态容器统一决定何时预取。
    let onPrefetchRepository: (RepositoryHoverEvent) -> Void

    private var repositoryCount: Int {
        groups.reduce(0) { $0 + $1.repositories.count }
    }

    var body: some View {
        // 选择、键盘导航、折叠动画全部交给系统 List，
        // 这里只负责行内的排版与星标视觉。
        List(selection: $selectionPath) {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: expansionBinding(for: group)) {
                    ForEach(group.repositories) { repository in
                        RepositoryRow(
                            repository: repository,
                            isStarred: starredRepositoryPaths.contains(repository.id),
                            onToggleStar: {
                                onToggleRepositoryStar(repository)
                            },
                            onHover: {
                                onPrefetchRepository($0)
                            }
                        )
                        .tag(repository.id)
                        // 组标题禁用选择后会传播到子行，这里显式恢复可选。
                        .selectionDisabled(false)
                        .accessibilityIdentifier("repository-\(repository.id)")
                    }
                } label: {
                    RepositoryGroupLabel(group: group)
                        .accessibilityIdentifier("repository-group-\(group.id)")
                }
                // 分组只用于展开/折叠，不参与仓库选择。
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Layout.minWidth, idealWidth: Layout.idealWidth, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: Layout.minWidth, ideal: Layout.idealWidth)
        .accessibilityIdentifier("repository-sidebar")
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Label("项目", systemImage: "folder")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)

                Text(repositoryCount, format: .number)
                    .font(Theme.Font.count)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, Theme.Spacing.textStack)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(repositoryCount) 个项目")

                Spacer(minLength: 0)

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在扫描项目")
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
        .overlay {
            // 空态只保留完成任务不可替代的一句：扫描中给诚实的进行态，
            // 扫完无结果说明位置（个人目录），不写教学式说明。
            if groups.isEmpty {
                if isScanning {
                    ContentUnavailableView {
                        Label("正在扫描本地仓库…", systemImage: "magnifyingglass")
                    } description: {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    ContentUnavailableView {
                        Label("暂无项目", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("未在个人目录发现 Git 仓库")
                    }
                }
            }
        }
    }

    /// 把「同时只展开一组」的既有策略接到 DisclosureGroup 的布尔绑定上。
    ///
    /// 展开与折叠都转交 `onToggleGroup`，由 ContentView 继续决定互斥逻辑，
    /// 避免这里和外部各存一份展开状态。
    private func expansionBinding(for group: RepositoryGroup) -> Binding<Bool> {
        Binding(
            get: { expandedGroupID == group.id },
            set: { isExpanded in
                guard isExpanded != (expandedGroupID == group.id) else { return }
                onToggleGroup(group.id)
            }
        )
    }
}

private struct RepositoryGroupLabel: View {
    let group: RepositoryGroup

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: Theme.Spacing.xs)

            // 组内有收藏项目时给个小星标，折叠状态下也能看出哪组重要。
            if group.starredRepositoryCount > 0 {
                Image(systemName: "star")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.Palette.starred)
            }

            Text(group.repositories.count, format: .number)
                .font(Theme.Font.count)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, Theme.Spacing.textStack)
                .background(.quaternary, in: Capsule())
        }
        .help(group.parentPath)
    }
}

private struct RepositoryRow: View {
    let repository: GitRepository
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onHover: (RepositoryHoverEvent) -> Void

    @State private var isHovering = false

    var body: some View {
        Label {
            HStack(spacing: Theme.Spacing.xs) {
                Text(repository.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Theme.Spacing.xs)

                // 星标始终占位，仅改变透明度，悬停时不会让文件名左右跳动。
                Button(action: onToggleStar) {
                    Image(systemName: "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isStarred ? AnyShapeStyle(Theme.Palette.starred) : AnyShapeStyle(.tertiary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(isStarred || isHovering ? 1 : 0)
                .allowsHitTesting(isStarred || isHovering)
                .accessibilityHidden(!isStarred && !isHovering)
                .accessibilityLabel(isStarred ? "取消收藏 \(repository.name)" : "收藏项目 \(repository.name)")
                .help(isStarred ? "取消收藏" : "收藏项目")
                .accessibilityIdentifier("repository-star-\(repository.id)")
            }
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(Theme.Palette.accent.opacity(0.78))
        }
        .padding(.vertical, Theme.Spacing.textStack)
        .onHover { isHovering in
            self.isHovering = isHovering
            // 进入与离开都原样上报：停留满一小段时间才预取，快速划过不再为每行各起 git 进程。
            onHover(isHovering ? .entered(repository) : .exited(repository))
        }
        .help(repository.path)
        .contextMenu {
            Button(isStarred ? "取消收藏" : "收藏项目", systemImage: isStarred ? "star.slash" : "star") {
                onToggleStar()
            }
        }
    }
}
