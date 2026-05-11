import Observation

@MainActor
@Observable
final class RepositoryStatusStore {
    private(set) var snapshot: RepositoryFileSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var snapshotRevision = 0

    @ObservationIgnored
    private let loader = GitRepositoryStatusLoader()
    @ObservationIgnored
    private var currentRepository: GitRepository?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    func load(for repository: GitRepository?) {
        loadTask?.cancel()
        loadTask = nil
        currentRepository = repository

        guard let repository else {
            resetState()
            return
        }

        if snapshot?.repositoryPath != repository.path {
            snapshot = nil
        }

        isLoading = true
        errorMessage = nil

        loadTask = Task {
            do {
                let snapshot = try await loader.loadSnapshot(for: repository)
                guard shouldApplyResult(for: repository) else { return }
                applySnapshot(snapshot)
            } catch {
                guard shouldApplyResult(for: repository) else { return }
                applyFailure(error)
            }
        }
    }

    func refreshCurrentRepository() {
        load(for: currentRepository)
    }

    private func resetState() {
        snapshot = nil
        isLoading = false
        errorMessage = nil
        snapshotRevision += 1
    }

    private func applySnapshot(_ snapshot: RepositoryFileSnapshot) {
        self.snapshot = snapshot
        isLoading = false
        errorMessage = nil
        snapshotRevision += 1
    }

    private func applyFailure(_ error: Error) {
        snapshot = nil
        isLoading = false
        errorMessage = GitCommandError.describe(error)
        snapshotRevision += 1
    }

    private func shouldApplyResult(for repository: GitRepository) -> Bool {
        !Task.isCancelled && currentRepository?.id == repository.id
    }
}
