import Foundation

/// Pure layer-tree diffing. Flattens nested `LayerNode` trees and compares them
/// by identity key (layer id when available, otherwise name), producing the
/// added/removed entries that drive the GitHub-style +N -N display.
enum LayerDiffer {

    /// Flattens a layer tree into (key, name) pairs, depth-first.
    /// `key` is `"id:<n>"` when the host exposes layer IDs, else `"name:<name>"`.
    static func flatten(_ nodes: [LayerNode]) -> [(key: String, name: String)] {
        var result: [(key: String, name: String)] = []
        func walk(_ node: LayerNode) {
            let key = node.id.map { "id:\($0)" } ?? "name:\(node.name)"
            result.append((key: key, name: node.name))
            node.children?.forEach { walk($0) }
        }
        nodes.forEach { walk($0) }
        return result
    }

    /// Computes the added/removed entries going from `old` to `new`.
    static func diff(from old: [LayerNode], to new: [LayerNode]) -> LayerDiff {
        let oldFlat = flatten(old)
        let newFlat = flatten(new)

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
}
