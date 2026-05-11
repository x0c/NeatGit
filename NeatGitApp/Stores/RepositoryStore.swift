import Foundation
import Observation

@MainActor
@Observable
final class RepositoryStore {
    private enum StorageKey {
        static let starredRepositoryPaths = "starredRepositoryPaths"
    }

    private(set) var repositories: [GitRepository] = []
    private(set) var isScanning = false
    private(set) var starredRepositoryPaths: Set<GitRepository.ID>

    @ObservationIgnored
    private let scanner = GitRepositoryScanner()
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.starredRepositoryPaths = Set(defaults.stringArray(forKey: StorageKey.starredRepositoryPaths) ?? [])
    }

    func refresh() {
        guard refreshTask == nil else { return }

        isScanning = true

        refreshTask = Task { [scanner] in
            defer {
                refreshTask = nil
                isScanning = false
            }

            repositories = await scanner.scan()
        }
    }

    func toggleStar(for repository: GitRepository) {
        if starredRepositoryPaths.contains(repository.id) {
            starredRepositoryPaths.remove(repository.id)
        } else {
            starredRepositoryPaths.insert(repository.id)
        }

        defaults.set(Array(starredRepositoryPaths).sorted(), forKey: StorageKey.starredRepositoryPaths)
    }
}
