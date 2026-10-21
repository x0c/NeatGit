import Foundation
import Observation

/// 工作区的选择态：选中仓库、展开分组、文件多选、悬停预览目标。
///
/// 这四份状态原先是 `ContentView` 里四个各自独立的 `@State`，
/// 它们之间的一致性靠三处 `onChange` 手工对齐（切仓库清空文件选择、
/// 仓库列表变化后校正选中项、文件列表变化后剔除失效 ID）。
/// 一致性规则散在视图的生命周期回调里，既难验证也容易漏改，
/// 这里收成一个容器：规则写成方法，视图只在事件发生时调用。
@MainActor
@Observable
final class WorkspaceSelectionStore {
    private(set) var selectedRepositoryID: GitRepository.ID?
    var expandedGroupID: RepositoryGroup.ID?
    var selectedFileIDs: Set<RepositoryFileItem.ID> = []
    private(set) var hoveredFileID: RepositoryFileItem.ID?

    func selectRepository(_ repositoryID: GitRepository.ID?, in repositories: [GitRepository]) {
        guard repositoryID != selectedRepositoryID else { return }

        selectedRepositoryID = repositoryID
        // 换仓库后旧的文件选中与悬停一律失效，避免把上一个仓库的文件带进新仓库。
        selectedFileIDs = []
        hoveredFileID = nil

        if let repositoryID,
           let repository = repositories.first(where: { $0.id == repositoryID }) {
            expandedGroupID = repository.parentPath
        }
    }

    func toggleGroup(_ groupID: RepositoryGroup.ID) {
        expandedGroupID = expandedGroupID == groupID ? nil : groupID
    }

    /// 扫描结果变化后校正：选中的仓库若已消失则清空，并保证始终有一个展开的分组。
    func reconcile(with repositories: [GitRepository], groups: [RepositoryGroup]) {
        let repositoryIDs = Set(repositories.map(\.id))

        if let selectedRepositoryID, !repositoryIDs.contains(selectedRepositoryID) {
            self.selectedRepositoryID = nil
            selectedFileIDs = []
            hoveredFileID = nil
        }

        let groupIDs = Set(groups.map(\.id))
        if let expandedGroupID, groupIDs.contains(expandedGroupID) {
            return
        }

        if let selectedRepositoryID,
           let repository = repositories.first(where: { $0.id == selectedRepositoryID }) {
            expandedGroupID = repository.parentPath
            return
        }

        expandedGroupID = groups.first?.id
    }

    /// 文件列表刷新后剔除已不存在的选中项与悬停项。
    func reconcileFiles(with fileIDs: [RepositoryFileItem.ID]) {
        guard selectedRepositoryID != nil else {
            selectedFileIDs = []
            hoveredFileID = nil
            return
        }

        let validFileIDs = Set(fileIDs)
        selectedFileIDs.formIntersection(validFileIDs)

        if let hoveredFileID, !validFileIDs.contains(hoveredFileID) {
            self.hoveredFileID = nil
        }
    }

    func selectFile(_ item: RepositoryFileItem) {
        selectedFileIDs = [item.id]
    }

    func updateHover(_ item: RepositoryFileItem, isHovering: Bool) {
        if isHovering {
            hoveredFileID = item.id
            return
        }

        // 只有仍停在同一行时才清空，避免移入下一行时把新目标误清。
        if hoveredFileID == item.id {
            hoveredFileID = nil
        }
    }

    func repository(in repositories: [GitRepository]) -> GitRepository? {
        guard let selectedRepositoryID else { return nil }
        return repositories.first { $0.id == selectedRepositoryID }
    }

    func selectedFiles(in snapshot: RepositoryFileSnapshot?) -> [RepositoryFileItem] {
        guard let snapshot else { return [] }
        return snapshot.allFiles.filter { selectedFileIDs.contains($0.id) }
    }

    func hoveredFile(in snapshot: RepositoryFileSnapshot?) -> RepositoryFileItem? {
        guard let snapshot, let hoveredFileID else { return nil }
        return snapshot.allFiles.first { $0.id == hoveredFileID }
    }
}
