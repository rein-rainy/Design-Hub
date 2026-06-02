import Foundation

/// SQLite-backed persistence for projects and commits. Owns the schema, its
/// migrations, all SQL, and row↔model mapping, so `VersionStore` can stay focused
/// on coordinating live state. All access is synchronous and single-threaded
/// (VersionStore drives it on @MainActor).
final class CommitRepository {

    private let db: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(db: Database) {
        self.db = db
        try? createSchema()
        migrate()
    }

    // MARK: - Reads

    func allProjects() -> [Project] {
        let rows = (try? db.query("SELECT * FROM projects ORDER BY created_at DESC")) ?? []
        return rows.compactMap { makeProject(from: $0) }
    }

    /// Commits for a project, newest first. Does not populate `layerDiff` —
    /// that is decorated by the caller across the returned sequence.
    func commits(forProjectID id: String) -> [Commit] {
        let rows = (try? db.query(
            "SELECT * FROM commits WHERE project_id = ? ORDER BY timestamp DESC",
            [.text(id)]
        )) ?? []
        return rows.compactMap { makeCommit(from: $0) }
    }

    // MARK: - Writes

    func insertProject(_ project: Project) {
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
    }

    func insertCommit(from message: PluginMessage,
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

    func setThumbnail(commitID: String, path: String) {
        try? db.run(
            "UPDATE commits SET thumbnail_path = ? WHERE id = ?",
            [.text(path), .text(commitID)]
        )
    }

    // MARK: - Schema

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

    // MARK: - Mapping

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
