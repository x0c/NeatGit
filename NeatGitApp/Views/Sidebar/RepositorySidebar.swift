import SwiftUI

struct RepositorySidebar: View {
    let groups: [RepositoryGroup]
    let didFinishInitialScan: Bool
    let starredRepositoryPaths: Set<GitRepository.ID>
    var searchQuery = ""
    @Binding var selectionPath: GitRepository.ID?
    @Binding var expandedGroupID: RepositoryGroup.ID?
    let onToggleGroup: (RepositoryGroup.ID) -> Void
    let onToggleRepositoryStar: (GitRepository) -> Void
    let onPrefetchRepository: (RepositoryHoverEvent) -> Void

    private var query: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matches: [GitRepository] {
        groups.flatMap(\.repositories).filter {
            $0.name.localizedStandardContains(query) ||
                ($0.path as NSString).abbreviatingWithTildeInPath.localizedStandardContains(query)
        }
    }

    var body: some View {
        let results = query.isEmpty ? [] : matches

        List(selection: $selectionPath) {
            if query.isEmpty {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: expansionBinding(for: group)) {
                        ForEach(group.repositories) { repository in
                            row(repository)
                        }
                    } label: {
                        Button {
                            onToggleGroup(group.id)
                        } label: {
                            RepositoryGroupLabel(group: group)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(expandedGroupID == group.id ? "已展开" : "已折叠")
                        .accessibilityIdentifier("repository-group-\(group.id)")
                    }
                    .selectionDisabled()
                }
            } else {
                ForEach(results) { repository in
                    row(repository, showsLocation: true)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 220, max: 300)
        .accessibilityIdentifier("repository-sidebar")
        .safeAreaBar(edge: .top, spacing: 0) {
            Text("仓库")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Theme.Workspace.headerHeight, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.lg)
        }
        .overlay {
            if !query.isEmpty && results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if groups.isEmpty && didFinishInitialScan {
                ContentUnavailableView("未找到仓库", systemImage: "folder")
            }
        }
    }

    private func row(_ repository: GitRepository, showsLocation: Bool = false) -> some View {
        RepositoryRow(
            repository: repository,
            showsLocation: showsLocation,
            isStarred: starredRepositoryPaths.contains(repository.id),
            onToggleStar: { onToggleRepositoryStar(repository) },
            onHover: onPrefetchRepository
        )
        .tag(repository.id)
        .selectionDisabled(false)
        .accessibilityIdentifier("repository-\(repository.id)")
    }

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
    @ScaledMetric(relativeTo: .callout) private var rowHeight = Theme.Workspace.rowHeight

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(group.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: Theme.Spacing.xs)
            if group.starredRepositoryCount > 0 {
                Image(systemName: "star")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(group.repositories.count, format: .number)
                .font(Theme.Font.count)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(group.repositories.count) 个仓库")
        }
        .frame(minHeight: rowHeight)
        .help(group.parentPath)
    }
}

private struct RepositoryRow: View {
    let repository: GitRepository
    let showsLocation: Bool
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onHover: (RepositoryHoverEvent) -> Void

    @State private var isHovering = false
    @ScaledMetric(relativeTo: .callout) private var rowHeight = Theme.Workspace.rowHeight

    var body: some View {
        Label {
            HStack(spacing: Theme.Spacing.xs) {
                Text(repository.name)
                    .font(.callout)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if showsLocation {
                    Text((repository.parentPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onToggleStar) {
                    Image(systemName: "star")
                        .font(.caption)
                        .foregroundStyle(isStarred ? AnyShapeStyle(Theme.Palette.starred) : AnyShapeStyle(.secondary))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(isStarred || isHovering ? 1 : 0)
                .allowsHitTesting(isStarred || isHovering)
                .accessibilityHidden(!isStarred && !isHovering)
                .accessibilityLabel(isStarred ? "取消收藏 \(repository.name)" : "收藏仓库 \(repository.name)")
                .help(isStarred ? "取消收藏" : "收藏仓库")
                .accessibilityIdentifier("repository-star-\(repository.id)")
            }
            .lineLimit(1)
        } icon: {
            Image(systemName: "folder")
        }
        .frame(minHeight: rowHeight)
        .onHover { isHovering in
            self.isHovering = isHovering
            onHover(isHovering ? .entered(repository) : .exited(repository))
        }
        .help(repository.path)
        .contextMenu {
            Button(isStarred ? "取消收藏" : "收藏仓库", systemImage: isStarred ? "star.slash" : "star") {
                onToggleStar()
            }
        }
    }
}
