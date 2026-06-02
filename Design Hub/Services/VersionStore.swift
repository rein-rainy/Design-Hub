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

    private let db: Database
    private var cancellables = Set<AnyCancellable>()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Factory

    static func makeDefault() throws -> VersionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DesignHub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(path: dir.appendingPathComponent("versions.db").path)
        return VersionStore(db: db)
    }

    // MARK: - Init

    init(db: Database) {
        self.db = db
        try? createSchema()
        migrate()
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
                self?.pendingMessage = PluginMessage(
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
                        artboardCount: nil,
                        artboardNames: nil
                    )
                )
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
        let msg = PluginMessage(
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
                artboardCount: nil,
                artboardNames: nil
            )
        )
        record(msg, commitMessage: "", isAutosave: true)
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
                self?.record(message, commitMessage: "", isAutosave: true)
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
                guard self.autoSaveEnabled else { continue }
                self.bridge?.requestSnapshot()
                print("[VersionStore] Auto-save snapshot requested")
            }
        }
    }

    // MARK: - Pending commit

    func confirmCommit(commitMessage: String) {
        guard let message = pendingMessage else { return }
        pendingMessage = nil
        record(message, commitMessage: commitMessage, isAutosave: false)
    }

    func cancelPending() {
        pendingMessage = nil
    }

    func layerDiffForPending() -> LayerDiff? {
        guard let message = pendingMessage else { return nil }
        return layerDiff(for: message)
    }

    func layerDiff(for message: PluginMessage) -> LayerDiff? {
        let path = message.payload.path.isEmpty
            ? "\(message.app.rawValue)://\(message.payload.name)"
            : message.payload.path
        guard let project = projects.first(where: { $0.path == path }),
              let lastCommit = commits(forProjectID: project.id).first
        else { return nil }
        return diffLayers(from: lastCommit.layerTree, to: message.payload.layerTree)
    }

    // MARK: - Public

    func commits(forProjectID id: String) -> [Commit] {
        commitCache[id] ?? []
    }

    // MARK: - Private: record

    private func record(_ message: PluginMessage, commitMessage: String = "", isAutosave: Bool = false) {
        let rawPath = message.payload.path.isEmpty
            ? "\(message.app.rawValue)://\(message.payload.name)"
            : message.payload.path
        let path = rawPath.hasPrefix("file://")
            ? (URL(string: rawPath)?.resolvingSymlinksInPath().path ?? rawPath)
            : (rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path : rawPath)
        let project = findOrCreate(path: path, name: message.payload.name, app: message.app)
        let commitID = UUID().uuidString
        let backupPath = backupFile(sourcePath: message.payload.path,
                                    commitID: commitID,
                                    projectID: project.id)
        insertCommit(from: message, projectID: project.id, commitID: commitID,
                     backupPath: backupPath, thumbnailPath: nil, commitMessage: commitMessage,
                     isAutosave: isAutosave)
        reload()

        // Generate thumbnail asynchronously; update DB + UI when done.
        if let backupPath {
            Task {
                let url = URL(fileURLWithPath: backupPath)
                guard let thumbURL = await ThumbnailGenerator.generate(from: url) else { return }
                try? db.run(
                    "UPDATE commits SET thumbnail_path = ? WHERE id = ?",
                    [.text(thumbURL.path), .text(commitID)]
                )
                reload()
                print("[VersionStore] Thumbnail saved for '\(message.payload.name)'")
            }
        }

        print("[VersionStore] Commit saved — '\(message.payload.name)' \(message.payload.layerCount) layers")
    }

    // MARK: - Private: file backup

    private func backupFile(sourcePath: String, commitID: String, projectID: String) -> String? {
        guard !sourcePath.isEmpty else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { return nil }

        let ext = URL(fileURLWithPath: sourcePath).pathExtension
        let destDir = backupDirectory(for: projectID)
        let destPath = destDir.appendingPathComponent("\(commitID).\(ext)").path

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: sourcePath, toPath: destPath)
            return destPath
        } catch {
            print("[VersionStore] Backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func backupDirectory(for projectID: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DesignHub/objects/\(projectID)", isDirectory: true)
    }

    // MARK: - Private: project

    private func findOrCreate(path: String, name: String, app: PluginMessage.AppSource) -> Project {
        if let existing = projects.first(where: { $0.path == path }) { return existing }

        let project = Project(id: UUID().uuidString, name: name, path: path, app: app, createdAt: Date())
        try? db.run(
            "INSERT INTO projects (id, name, path, app, created_at) VALUES (?, ?, ?, ?, ?)",
            [
                .text(project.id),
                .text(project.name),
                .text(project.path),
                .text(project.app.rawValue),
                .integer(Int64(project.createdAt.timeIntervalSince1970)),
            ]
        )
        return project
    }

    // MARK: - Private: reload

    private func reload() {
        let rows = (try? db.query("SELECT * FROM projects ORDER BY created_at DESC")) ?? []
        projects = rows.compactMap { makeProject(from: $0) }

        var cache: [String: [Commit]] = [:]
        for project in projects {
            cache[project.id] = fetchCommits(forProjectID: project.id)
        }
        commitCache = cache
    }

    private func fetchCommits(forProjectID id: String) -> [Commit] {
        let rows = (try? db.query(
            "SELECT * FROM commits WHERE project_id = ? ORDER BY timestamp DESC",
            [.text(id)]
        )) ?? []

        var commits = rows.compactMap { makeCommit(from: $0) }
        for i in 0..<commits.count {
            let prev = i + 1 < commits.count ? commits[i + 1] : nil
            if let prev {
                commits[i].layerDiff = diffLayers(from: prev.layerTree, to: commits[i].layerTree)
            }
        }
        return commits
    }

    private func flattenLayers(_ nodes: [LayerNode]) -> [(key: String, name: String)] {
        var result: [(key: String, name: String)] = []
        func walk(_ node: LayerNode) {
            let key = node.id.map { "id:\($0)" } ?? "name:\(node.name)"
            result.append((key: key, name: node.name))
            node.children?.forEach { walk($0) }
        }
        nodes.forEach { walk($0) }
        return result
    }

    private func diffLayers(from old: [LayerNode], to new: [LayerNode]) -> LayerDiff {
        let oldFlat = flattenLayers(old)
        let newFlat = flattenLayers(new)

        let oldKeys = oldFlat.reduce(into: [String: String]()) { $0[$1.key] = $1.name }
        let newKeys = newFlat.reduce(into: [String: String]()) { $0[$1.key] = $1.name }

        let added = newFlat
            .filter { oldKeys[$0.key] == nil }
            .map { LayerDiff.Entry(id: $0.key, name: $0.name) }

        let removed = oldFlat
            .filter { newKeys[$0.key] == nil }
            .map { LayerDiff.Entry(id: $0.key, name: $0.name) }

        return LayerDiff(added: added, removed: removed)
    }

    // MARK: - Private: commit insert

    private func insertCommit(from message: PluginMessage,
                               projectID: String,
                               commitID: String,
                               backupPath: String?,
                               thumbnailPath: String?,
                               commitMessage: String = "",
                               isAutosave: Bool = false) {
        let treeJSON = (try? encoder.encode(message.payload.layerTree))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try? db.run(
            """
            INSERT INTO commits
              (id, project_id, timestamp, layer_count, top_level_layer_count,
               artboard_count, layer_tree, is_autosave, message, backup_path, thumbnail_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(commitID),
                .text(projectID),
                .integer(Int64(Date().timeIntervalSince1970)),
                .integer(Int64(message.payload.layerCount)),
                .integer(Int64(message.payload.topLevelLayerCount)),
                message.payload.artboardCount.map { .integer(Int64($0)) } ?? .null,
                .text(treeJSON),
                .integer(isAutosave ? 1 : 0),
                .text(commitMessage),
                backupPath.map { .text($0) } ?? .null,
                thumbnailPath.map { .text($0) } ?? .null,
            ]
        )
    }

    // MARK: - Private: schema

    private func createSchema() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS projects (
                id         TEXT PRIMARY KEY,
                name       TEXT NOT NULL,
                path       TEXT NOT NULL UNIQUE,
                app        TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS commits (
                id                    TEXT PRIMARY KEY,
                project_id            TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                timestamp             INTEGER NOT NULL,
                layer_count           INTEGER NOT NULL,
                top_level_layer_count INTEGER NOT NULL,
                artboard_count        INTEGER,
                layer_tree            TEXT NOT NULL DEFAULT '[]',
                is_autosave           INTEGER NOT NULL DEFAULT 1,
                message               TEXT NOT NULL DEFAULT '',
                backup_path           TEXT,
                thumbnail_path        TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_commits_project ON commits(project_id, timestamp);
        """)
    }

    private func migrate() {
        let existing = (try? db.query("PRAGMA table_info(commits)"))?.compactMap { $0["name"]?.string } ?? []
        if !existing.contains("backup_path") {
            try? db.exec("ALTER TABLE commits ADD COLUMN backup_path TEXT")
        }
        if !existing.contains("thumbnail_path") {
            try? db.exec("ALTER TABLE commits ADD COLUMN thumbnail_path TEXT")
        }
    }

    // MARK: - Private: mapping

    private func makeProject(from row: [String: Database.Value]) -> Project? {
        guard
            let id     = row["id"]?.string,
            let name   = row["name"]?.string,
            let path   = row["path"]?.string,
            let appRaw = row["app"]?.string,
            let app    = PluginMessage.AppSource(rawValue: appRaw),
            let ts     = row["created_at"]?.int64
        else { return nil }
        return Project(id: id, name: name, path: path, app: app,
                       createdAt: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func makeCommit(from row: [String: Database.Value]) -> Commit? {
        guard
            let id         = row["id"]?.string,
            let projectID  = row["project_id"]?.string,
            let ts         = row["timestamp"]?.int64,
            let layers     = row["layer_count"]?.int,
            let topLayers  = row["top_level_layer_count"]?.int,
            let treeJSON   = row["layer_tree"]?.string,
            let isAutosave = row["is_autosave"]?.int
        else { return nil }

        let tree = (try? decoder.decode([LayerNode].self, from: Data(treeJSON.utf8))) ?? []

        return Commit(
            id: id,
            projectID: projectID,
            timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
            layerCount: layers,
            topLevelLayerCount: topLayers,
            artboardCount: row["artboard_count"]?.int,
            layerTree: tree,
            isAutosave: isAutosave == 1,
            message: row["message"]?.string ?? "",
            backupPath: row["backup_path"]?.string,
            thumbnailPath: row["thumbnail_path"]?.string
        )
    }
}
