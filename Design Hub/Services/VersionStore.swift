import Foundation
import Combine

extension NSNotification.Name {
    static let simulateFileSave    = NSNotification.Name("DesignHub.simulateFileSave")
    static let simulateAutoSaveNow = NSNotification.Name("DesignHub.simulateAutoSaveNow")
}

@MainActor
final class VersionStore: ObservableObject {

    @Published private(set) var projects: [Project] = []
    /// Reactive commit cache — updated after every save and after thumbnail generation.
    @Published private(set) var commitCache: [String: [Commit]] = [:]
    /// Pending save waiting for user confirmation via the commit panel.
    /// Uses didSet (not @Published) so the callback fires after the value is set,
    /// avoiding @Published's willSet timing issue with Swift Concurrency tasks.
    private(set) var pendingMessage: PluginMessage? = nil {
        didSet { onPendingMessageChanged?(pendingMessage) }
    }
    var onPendingMessageChanged: ((PluginMessage?) -> Void)?

    // MARK: - Auto-save
    @Published var autoSaveEnabled: Bool = true
    private weak var bridge: PluginBridgeServer? = nil
    private var autoSaveTimerTask: Task<Void, Never>? = nil
    /// Fired just before an auto-save snapshot request. DocumentSaveWatcher uses
    /// this to ignore the file write our own request is about to cause.
    var onAutoSaveRequested: (() -> Void)?

    private let repository: CommitRepository
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Factory

    static func makeDefault() throws -> VersionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DesignHub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(path: dir.appendingPathComponent("versions.db").path)
        return VersionStore(db: db)
    }

    // MARK: - Init

    /// Auto-saves are transient history — keep only the last two weeks of them.
    private static let autoSaveRetention: TimeInterval = 14 * 24 * 60 * 60

    init(db: Database) {
        self.repository = CommitRepository(db: db)
        purgeExpiredAutosaves()
        reload()
    }

    /// Removes auto-save commits older than the retention window, along with their
    /// on-disk backup and thumbnail files. Manual commits are kept indefinitely.
    private func purgeExpiredAutosaves() {
        let cutoff = Date().addingTimeInterval(-Self.autoSaveRetention)
        let expired = repository.deleteExpiredAutosaves(olderThan: cutoff)
        guard !expired.isEmpty else { return }

        let fm = FileManager.default
        for commit in expired {
            if let path = commit.backupPath { try? fm.removeItem(atPath: path) }
            if let path = commit.thumbnailPath { try? fm.removeItem(atPath: path) }
        }
        print("[VersionStore] Purged \(expired.count) expired auto-save(s)")
        reload()
    }

    // MARK: - Bridge subscription

    func subscribeToDebugSimulation() {
        NotificationCenter.default.addObserver(
            forName: .simulateFileSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pendingMessage = Self.makeSimulatedSaveMessage()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .simulateAutoSaveNow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.simulateAutoSaveNow()
            }
        }
    }

    func simulateAutoSaveNow() {
        record(Self.makeSimulatedSaveMessage(), commitMessage: "", isAutosave: true)
    }

    func subscribe(to bridge: PluginBridgeServer) {
        self.bridge = bridge
        cancellables.removeAll()

        bridge.messagePublisher
            .filter { $0.type == .documentSaved }
            .sink { [weak self] message in
                self?.pendingMessage = message
            }
            .store(in: &cancellables)

        bridge.messagePublisher
            .filter { $0.type == .snapshotRequested }
            .sink { [weak self] message in
                guard let self else { return }
                guard self.hasExistingCommit(for: message) else {
                    print("[VersionStore] Auto-save skipped — project has no manual commit yet")
                    return
                }
                guard self.hasChanges(for: message) else {
                    print("[VersionStore] Auto-save skipped — no changes since last commit")
                    return
                }
                self.record(message, commitMessage: "", isAutosave: true)
            }
            .store(in: &cancellables)

        startAutoSaveTimer()
    }

    private func startAutoSaveTimer() {
        autoSaveTimerTask?.cancel()
        autoSaveTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled, let self else { break }
                self.purgeExpiredAutosaves()
                guard self.autoSaveEnabled else { continue }
                self.onAutoSaveRequested?()
                self.bridge?.requestSnapshot()
                print("[VersionStore] Auto-save snapshot requested")
            }
        }
    }

    // MARK: - Pending commit

    func confirmCommit(commitMessage: String) {
        guard let message = pendingMessage else { return }
        pendingMessage = nil
        // Fall back to a timestamped title ("Commit {date}") when the user commits
        // without typing a message, instead of leaving it blank.
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Commit \(Self.defaultMessageDateFormatter.string(from: Date()))" : trimmed
        record(message, commitMessage: resolved, isAutosave: false)
    }

    private static let defaultMessageDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    func cancelPending() {
        pendingMessage = nil
    }

    func layerDiffForPending() -> LayerDiff? {
        guard let message = pendingMessage else { return nil }
        return layerDiff(for: message)
    }

    /// Returns true if the message's project already has at least one
    /// user-created (non-autosave) commit. Auto-saves only kick in after the
    /// first manual commit, so brand-new files are never auto-committed.
    func hasExistingCommit(for message: PluginMessage) -> Bool {
        guard let project = projects.first(where: { $0.path == canonicalPath(for: message) }) else {
            return false
        }
        return commits(forProjectID: project.id).contains { !$0.isAutosave }
    }

    /// Returns true if the incoming snapshot differs from the latest commit for
    /// its project. Used to skip auto-saves when nothing has changed.
    func hasChanges(for message: PluginMessage) -> Bool {
        guard let project = projects.first(where: { $0.path == canonicalPath(for: message) }),
              let lastCommit = commits(forProjectID: project.id).first
        else {
            // No prior commit for this project — always treat as a change.
            return true
        }

        // Prefer comparing the actual file bytes against the last backup.
        if !message.payload.path.isEmpty,
           let backupPath = lastCommit.backupPath,
           FileManager.default.fileExists(atPath: message.payload.path),
           FileManager.default.fileExists(atPath: backupPath) {
            return !FileManager.default.contentsEqual(atPath: message.payload.path,
                                                      andPath: backupPath)
        }

        // Fallback (unsaved/simulated docs): compare shape count + layer structure.
        let diff = LayerDiffer.diff(from: lastCommit.layerTree, to: message.payload.layerTree)
        return !diff.isEmpty
            || lastCommit.shapeCount != message.payload.shapeCount
            || lastCommit.layerCount != message.payload.layerCount
            || lastCommit.topLevelLayerCount != message.payload.topLevelLayerCount
            || lastCommit.artboardCount != message.payload.artboardCount
    }

    /// Shapes added/removed between the incoming snapshot and the latest commit
    /// (Illustrator only). Drives the pending commit panel's +N/-N badge.
    func shapeChangeForPending() -> ShapeChange? {
        guard let message = pendingMessage else { return nil }
        return shapeChange(for: message)
    }

    func shapeChange(for message: PluginMessage) -> ShapeChange? {
        guard let project = projects.first(where: { $0.path == canonicalPath(for: message) }),
              let lastCommit = commits(forProjectID: project.id).first
        else { return nil }
        return ShapeChange.between(oldIds: lastCommit.shapeIds, oldCount: lastCommit.shapeCount,
                                   newIds: message.payload.shapeIds, newCount: message.payload.shapeCount)
    }

    func layerDiff(for message: PluginMessage) -> LayerDiff? {
        guard let project = projects.first(where: { $0.path == canonicalPath(for: message) }),
              let lastCommit = commits(forProjectID: project.id).first
        else { return nil }
        return LayerDiffer.diff(from: lastCommit.layerTree, to: message.payload.layerTree)
    }

    // MARK: - Public

    func commits(forProjectID id: String) -> [Commit] {
        commitCache[id] ?? []
    }

    // MARK: - Edit / delete

    /// Renames a commit's message. An empty/whitespace-only string clears it back
    /// to the "No message" placeholder behaviour.
    func rename(commit: Commit, to newMessage: String) {
        let trimmed = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        repository.updateMessage(commitID: commit.id, message: trimmed)
        reload()
    }

    /// Permanently deletes a commit and its on-disk backup + thumbnail files.
    func delete(commit: Commit) {
        repository.deleteCommit(commitID: commit.id)
        let fm = FileManager.default
        if let path = commit.backupPath { try? fm.removeItem(atPath: path) }
        if let path = commit.thumbnailPath { try? fm.removeItem(atPath: path) }
        reload()
    }

    // MARK: - Restore

    /// Restores a commit's backup as a new file alongside the project's original
    /// file. The original is never overwritten — instead a sibling file named
    /// `<name>_restored_<timestamp>.<ext>` is created in the same directory.
    /// Returns the URL of the file that was written, or `nil` on failure.
    @discardableResult
    func restore(commit: Commit) -> URL? {
        guard let backupPath = commit.backupPath else {
            print("[VersionStore] Restore failed — commit has no backup")
            return nil
        }
        guard let project = projects.first(where: { $0.id == commit.projectID }) else {
            print("[VersionStore] Restore failed — project not found")
            return nil
        }

        // Resolve the original file's on-disk location. Virtual paths (e.g.
        // "photoshop://Untitled.psd") have no real directory to restore into.
        let originalPath = project.path
        guard originalPath.hasPrefix("/") || originalPath.hasPrefix("file://") else {
            print("[VersionStore] Restore failed — original file was never saved to disk")
            return nil
        }
        let originalURL = originalPath.hasPrefix("file://")
            ? (URL(string: originalPath) ?? URL(fileURLWithPath: originalPath))
            : URL(fileURLWithPath: originalPath)

        return BackupManager.restore(backupPath: backupPath,
                                     originalURL: originalURL,
                                     timestamp: commit.timestamp)
    }

    // MARK: - Private: record

    private func record(_ message: PluginMessage, commitMessage: String = "", isAutosave: Bool = false) {
        let path = resolvedPath(for: message)
        let project = findOrCreate(path: path, name: message.payload.name, app: message.app)
        let commitID = UUID().uuidString
        let backupPath = BackupManager.backup(sourcePath: message.payload.path,
                                              commitID: commitID,
                                              projectID: project.id)
        repository.insertCommit(from: message, projectID: project.id, commitID: commitID,
                                backupPath: backupPath, thumbnailPath: nil, commitMessage: commitMessage,
                                isAutosave: isAutosave)
        reload()

        // Generate thumbnail asynchronously; update DB + UI when done.
        if let backupPath {
            Task {
                let url = URL(fileURLWithPath: backupPath)
                guard let thumbURL = await ThumbnailGenerator.generate(from: url) else { return }
                repository.setThumbnail(commitID: commitID, path: thumbURL.path)
                reload()
                print("[VersionStore] Thumbnail saved for '\(message.payload.name)'")
            }
        }

        print("[VersionStore] Commit saved — '\(message.payload.name)' \(message.payload.layerCount) layers")

        if isAutosave {
            AutoSaveNotifier.notify(documentName: message.payload.name)
        }
    }

    // MARK: - Private: project

    private func findOrCreate(path: String, name: String, app: PluginMessage.AppSource) -> Project {
        if let existing = projects.first(where: { $0.path == path }) { return existing }

        let project = Project(id: UUID().uuidString, name: name, path: path, app: app, createdAt: Date())
        repository.insertProject(project)
        return project
    }

    // MARK: - Private: reload

    private func reload() {
        projects = repository.allProjects()

        var cache: [String: [Commit]] = [:]
        for project in projects {
            var commits = repository.commits(forProjectID: project.id)
            // Decorate each commit with the diff against its immediate predecessor.
            for i in 0..<commits.count {
                if i + 1 < commits.count {
                    commits[i].layerDiff = LayerDiffer.diff(from: commits[i + 1].layerTree,
                                                            to: commits[i].layerTree)
                    commits[i].shapeChange = ShapeChange.between(
                        oldIds: commits[i + 1].shapeIds, oldCount: commits[i + 1].shapeCount,
                        newIds: commits[i].shapeIds, newCount: commits[i].shapeCount)
                }
            }
            cache[project.id] = commits
        }
        commitCache = cache
    }

    // MARK: - Private: path helpers

    /// The identity path used to match a message to a project. Unsaved documents
    /// have no filesystem path, so they get a virtual "<app>://<name>" key.
    private func canonicalPath(for message: PluginMessage) -> String {
        message.payload.path.isEmpty
            ? "\(message.app.rawValue)://\(message.payload.name)"
            : message.payload.path
    }

    /// Like `canonicalPath`, but resolves symlinks for real on-disk paths so the
    /// same file is never recorded under two different paths.
    private func resolvedPath(for message: PluginMessage) -> String {
        let raw = canonicalPath(for: message)
        if raw.hasPrefix("file://") {
            return URL(string: raw)?.resolvingSymlinksInPath().path ?? raw
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        }
        return raw
    }

    // MARK: - Private: debug

    private static func makeSimulatedSaveMessage() -> PluginMessage {
        PluginMessage(
            version: 1,
            type: .documentSaved,
            app: .photoshop,
            timestamp: Date(),
            payload: DocumentPayload(
                path: "",
                name: "Untitled.psd",
                layerCount: 5,
                topLevelLayerCount: 3,
                layerTree: [],
                shapeCount: nil,
                shapeIds: nil,
                artboardCount: nil,
                artboardNames: nil
            )
        )
    }
}
