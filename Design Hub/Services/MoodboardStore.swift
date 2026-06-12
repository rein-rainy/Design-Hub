import AppKit
import Combine
import Foundation

/// SQLite-backed store for per-file moodboards. Each selected design file gets its
/// own board (keyed by the file's resolved path). Image bytes are copied into a
/// dedicated images directory under Application Support; geometry lives in
/// `moodboard.db`. Runs entirely on `@MainActor`, like `VersionStore`.
///
/// Note: `Database` only binds TEXT / INTEGER, so geometry is persisted as whole
/// points (rounded). Sub-pixel precision isn't meaningful for a reference board.
@MainActor
final class MoodboardStore: ObservableObject {

    /// Items for the currently loaded board, sorted bottom-to-top by `z`.
    @Published private(set) var items: [MoodboardItem] = []
    private(set) var boardKey: String?

    private let db: Database
    private let imagesDir: URL

    /// Longest side of a freshly added image, in board points.
    private let initialMaxDimension: CGFloat = 360
    /// Smallest a side may be shrunk to via the resize handle.
    let minItemDimension: CGFloat = 40

    // MARK: - Factory

    static func makeDefault() throws -> MoodboardStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DesignHub", isDirectory: true)
        let images = dir.appendingPathComponent("Moodboard/images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let db = try Database(path: dir.appendingPathComponent("moodboard.db").path)
        return MoodboardStore(db: db, imagesDir: images)
    }

    init(db: Database, imagesDir: URL) {
        self.db = db
        self.imagesDir = imagesDir
        try? createSchema()
    }

    private func createSchema() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS moodboard_items (
                id         TEXT PRIMARY KEY,
                board_key  TEXT NOT NULL,
                filename   TEXT NOT NULL,
                x          INTEGER NOT NULL,
                y          INTEGER NOT NULL,
                width      INTEGER NOT NULL,
                height     INTEGER NOT NULL,
                z          INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_moodboard_board ON moodboard_items(board_key, z);
        """)
    }

    // MARK: - Board loading

    /// Loads the board for `key`, replacing the current items. Passing `nil` (no
    /// file selected) clears the board.
    func load(key: String?) {
        boardKey = key
        guard let key, !key.isEmpty else {
            items = []
            return
        }
        let rows = (try? db.query(
            "SELECT * FROM moodboard_items WHERE board_key = ? ORDER BY z ASC",
            [.text(key)]
        )) ?? []
        items = rows.compactMap(makeItem)
    }

    // MARK: - Image source

    /// Absolute on-disk URL backing an item's image.
    func imageURL(for item: MoodboardItem) -> URL {
        imagesDir.appendingPathComponent(item.filename)
    }

    // MARK: - Mutations

    /// Copies `data` into the images directory and pins it to the current board,
    /// centered on `point` (board coordinates). No-op if no board is loaded or the
    /// data isn't a decodable image.
    @discardableResult
    func addImage(data: Data, fileExtension: String, at point: CGPoint) -> MoodboardItem? {
        guard let key = boardKey, !key.isEmpty else { return nil }
        guard let pixelSize = Self.pixelSize(of: data) else { return nil }

        let id = UUID().uuidString
        let ext = sanitizedExtension(fileExtension)
        let filename = "\(id).\(ext)"
        let url = imagesDir.appendingPathComponent(filename)
        do {
            try data.write(to: url)
        } catch {
            return nil
        }

        let display = initialDisplaySize(for: pixelSize)
        let z = (items.map(\.z).max() ?? 0) + 1
        let item = MoodboardItem(
            id: id, boardKey: key, filename: filename,
            x: point.x.rounded(), y: point.y.rounded(),
            width: display.width.rounded(), height: display.height.rounded(),
            z: z, createdAt: Date()
        )
        insert(item)
        items.append(item)
        return item
    }

    func move(_ id: String, to point: CGPoint) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].x = point.x.rounded()
        items[idx].y = point.y.rounded()
        let item = items[idx]
        try? db.run(
            "UPDATE moodboard_items SET x = ?, y = ? WHERE id = ?",
            [.integer(Int64(item.x)), .integer(Int64(item.y)), .text(id)]
        )
    }

    func resize(_ id: String, to size: CGSize) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let w = max(minItemDimension, size.width).rounded()
        let h = max(minItemDimension, size.height).rounded()
        items[idx].width = w
        items[idx].height = h
        try? db.run(
            "UPDATE moodboard_items SET width = ?, height = ? WHERE id = ?",
            [.integer(Int64(w)), .integer(Int64(h)), .text(id)]
        )
    }

    /// Promotes an item to the top of the stack so it draws above the others.
    func bringToFront(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let topZ = items.map(\.z).max() ?? 0
        guard item.z != topZ else { return }
        let newZ = topZ + 1
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].z = newZ
            items.sort { $0.z < $1.z }
        }
        try? db.run("UPDATE moodboard_items SET z = ? WHERE id = ?",
                    [.integer(Int64(newZ)), .text(id)])
    }

    func delete(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: imageURL(for: item))
        try? db.run("DELETE FROM moodboard_items WHERE id = ?", [.text(id)])
        items.removeAll { $0.id == id }
    }

    // MARK: - Persistence helpers

    private func insert(_ item: MoodboardItem) {
        try? db.run(
            """
            INSERT INTO moodboard_items (id, board_key, filename, x, y, width, height, z, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(item.id),
                .text(item.boardKey),
                .text(item.filename),
                .integer(Int64(item.x)),
                .integer(Int64(item.y)),
                .integer(Int64(item.width)),
                .integer(Int64(item.height)),
                .integer(Int64(item.z)),
                .integer(Int64(item.createdAt.timeIntervalSince1970)),
            ]
        )
    }

    private func makeItem(from row: [String: Database.Value]) -> MoodboardItem? {
        guard
            let id       = row["id"]?.string,
            let key      = row["board_key"]?.string,
            let filename = row["filename"]?.string,
            let x        = row["x"]?.int,
            let y        = row["y"]?.int,
            let width    = row["width"]?.int,
            let height   = row["height"]?.int,
            let z        = row["z"]?.int,
            let created  = row["created_at"]?.int64
        else { return nil }
        return MoodboardItem(
            id: id, boardKey: key, filename: filename,
            x: CGFloat(x), y: CGFloat(y),
            width: CGFloat(width), height: CGFloat(height),
            z: z, createdAt: Date(timeIntervalSince1970: TimeInterval(created))
        )
    }

    // MARK: - Sizing

    /// Initial display size: scaled down so its longest side is `initialMaxDimension`,
    /// never scaled up past the image's natural pixel size.
    private func initialDisplaySize(for pixelSize: CGSize) -> CGSize {
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return CGSize(width: initialMaxDimension, height: initialMaxDimension) }
        let factor = longest > initialMaxDimension ? initialMaxDimension / longest : 1
        return CGSize(width: pixelSize.width * factor, height: pixelSize.height * factor)
    }

    /// Native pixel dimensions of encoded image bytes.
    private static func pixelSize(of data: Data) -> CGSize? {
        if let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        if let image = NSImage(data: data), image.size.width > 0 {
            return image.size
        }
        return nil
    }

    private func sanitizedExtension(_ ext: String) -> String {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "png" : trimmed
    }
}
