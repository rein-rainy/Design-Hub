import Foundation

// Matches the JSON protocol sent by the Photoshop and Illustrator UXP plugins.

struct PluginMessage: Codable {
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

struct DocumentPayload: Codable {
    let path: String
    let name: String
    let layerCount: Int
    let topLevelLayerCount: Int
    let layerTree: [LayerNode]
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
    }
}
