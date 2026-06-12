import Foundation

// Matches the JSON protocol sent by the Photoshop (UXP) and Illustrator (CEP) plugins.

struct PluginMessage: Codable, Equatable {
    let version: Int
    let type: EventType
    let app: AppSource
    let timestamp: Date
    let payload: DocumentPayload

    enum EventType: String, Codable {
        case documentOpened    = "document_opened"
        case documentSaved     = "document_saved"
        case documentClosed    = "document_closed"
        case snapshotRequested = "snapshot_requested"
    }

    enum AppSource: String, Codable {
        case photoshop
        case illustrator
    }
}

struct DocumentPayload: Codable, Equatable {
    let path: String
    let name: String
    let layerCount: Int
    let topLevelLayerCount: Int
    let layerTree: [LayerNode]
    // Illustrator only — total shape (pageItem) count, nil for Photoshop messages.
    // Drives the heatmap/diff because AI work changes shapes far more than layers.
    let shapeCount: Int?
    // Illustrator only — uuid of every pageItem, so commits can be diffed into
    // "+N added / -N removed" shapes instead of a net count change. May be
    // shorter than shapeCount on Illustrator versions without pageItem.uuid;
    // consumers must treat that as "no identity data" and fall back.
    let shapeIds: [String]?
    // Illustrator only — nil for Photoshop messages
    let artboardCount: Int?
    let artboardNames: [String]?
}

struct LayerNode: Codable, Identifiable, Equatable, Hashable {
    let id: Int?   // nil when the host app doesn't expose layer IDs
    let name: String
    // Photoshop: "pixel" | "text" | "group" | "smartObject" | etc.
    // Illustrator: nil (AI layers have no kind)
    let kind: String?
    let visible: Bool
    let locked: Bool?
    let children: [LayerNode]?

    var totalCount: Int {
        1 + (children ?? []).reduce(0) { $0 + $1.totalCount }
    }
}

// MARK: - Commands (macOS app → plugin)

struct PluginCommand: Encodable {
    let type: CommandType

    enum CommandType: String, Encodable {
        case requestSnapshot = "request_snapshot"
        // Sent when DocumentSaveWatcher sees the file change on disk: the user
        // already saved, so the plugin replies with a `document_saved` snapshot
        // without saving again.
        case requestSaveSnapshot = "request_save_snapshot"
    }
}
