import Foundation

struct LayerDiff: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String   // "id:123" or "name:Layer 1"
        let name: String
    }
    let added: [Entry]
    let removed: [Entry]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

struct Commit: Identifiable, Equatable {
    let id: String
    let projectID: String
    let timestamp: Date
    let layerCount: Int
    let topLevelLayerCount: Int
    let artboardCount: Int?
    let layerTree: [LayerNode]
    let isAutosave: Bool
    var message: String
    let backupPath: String?
    let thumbnailPath: String?

    var layerDiff: LayerDiff? = nil  // filled in by VersionStore when loaded in sequence

    var hasBackup: Bool { backupPath != nil }
    var hasThumbnail: Bool { thumbnailPath != nil }
}
