import Foundation

/// Shapes added and removed between two snapshots (Illustrator only).
/// Computed from pageItem uuid sets when both snapshots carry them; otherwise
/// derived from the net shape-count delta (which can't see e.g. "+3 / -2").
struct ShapeChange: Equatable {
    let added: Int
    let removed: Int

    var isEmpty: Bool { added == 0 && removed == 0 }

    /// Diffs two snapshots' shapes by pageItem uuid, so "+3 / -2" is reported
    /// instead of a net "+1". An id list shorter than its shape count means the
    /// host couldn't read every uuid — identity is unreliable, so fall back to
    /// the net count delta. Returns nil when either side has no shape count
    /// (Photoshop, or pre-shapeCount commits).
    static func between(oldIds: [String]?, oldCount: Int?,
                        newIds: [String]?, newCount: Int?) -> ShapeChange? {
        guard let oldCount, let newCount else { return nil }
        if let oldIds, let newIds, oldIds.count == oldCount, newIds.count == newCount {
            let oldSet = Set(oldIds)
            let newSet = Set(newIds)
            // Duplicate uuids would make the sets undercount; only trust them
            // when every shape is uniquely identified.
            if oldSet.count == oldCount && newSet.count == newCount {
                return ShapeChange(added: newSet.subtracting(oldSet).count,
                                   removed: oldSet.subtracting(newSet).count)
            }
        }
        let delta = newCount - oldCount
        return ShapeChange(added: max(delta, 0), removed: max(-delta, 0))
    }
}

struct LayerDiff: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String   // "id:123" or "name:Layer 1"
        let name: String
    }
    let added: [Entry]
    let removed: [Entry]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// The +added / -removed counts shown on a commit, preferring shape churn
/// (Illustrator) over layer-tree diffing (Photoshop). A nil `shapeChange` falls
/// back to the layer diff so Photoshop commits are unaffected. An empty change
/// also falls back: it can hide structural changes like an added empty layer.
enum ChangeBadge {
    static func counts(shapeChange: ShapeChange?, layerDiff: LayerDiff?) -> (added: Int, removed: Int) {
        if let change = shapeChange, !change.isEmpty {
            return (added: change.added, removed: change.removed)
        }
        if let diff = layerDiff {
            return (added: diff.added.count, removed: diff.removed.count)
        }
        return (0, 0)
    }
}

struct Commit: Identifiable, Equatable {
    let id: String
    let projectID: String
    let timestamp: Date
    let layerCount: Int
    let topLevelLayerCount: Int
    let artboardCount: Int?
    let shapeCount: Int?   // Illustrator only — total pageItem count; nil for Photoshop
    // Illustrator only — pageItem uuids at commit time, used to diff shapes by
    // identity. nil for Photoshop and commits made before uuids were recorded.
    let shapeIds: [String]?
    let layerTree: [LayerNode]
    let isAutosave: Bool
    var message: String
    let backupPath: String?
    let thumbnailPath: String?

    var layerDiff: LayerDiff? = nil  // filled in by VersionStore when loaded in sequence
    /// Shapes added/removed vs the immediate predecessor (Illustrator only).
    /// Filled in by VersionStore alongside `layerDiff`; nil when either commit
    /// lacks a shape count (e.g. Photoshop, or the oldest commit).
    var shapeChange: ShapeChange? = nil

    var hasBackup: Bool { backupPath != nil }
    var hasThumbnail: Bool { thumbnailPath != nil }
}
