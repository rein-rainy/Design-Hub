import Foundation

struct Project: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let path: String
    let app: PluginMessage.AppSource
    let createdAt: Date

    var displayName: String { name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name }
}
