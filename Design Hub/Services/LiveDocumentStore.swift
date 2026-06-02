import Foundation
import Combine

/// A document currently open in Photoshop or Illustrator, as reported by the
/// plugins via the bridge. Drives the "live" group at the top of the sidebar.
struct LiveDocument: Identifiable, Equatable {
    let app: PluginMessage.AppSource
    let path: String   // "" for an unsaved (Untitled) document
    let name: String

    var id: String { path.isEmpty ? "\(app.rawValue)://\(name)" : path }
    var hasFile: Bool { !path.isEmpty }
    var url: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }
}

/// Tracks the set of documents currently open in the connected design apps.
/// Open/save events add or refresh an entry; close events remove it.
@MainActor
final class LiveDocumentStore: ObservableObject {
    @Published private(set) var documents: [LiveDocument] = []

    private var cancellables = Set<AnyCancellable>()

    func subscribe(to bridge: PluginBridgeServer) {
        cancellables.removeAll()
        bridge.messagePublisher
            .sink { [weak self] message in self?.handle(message) }
            .store(in: &cancellables)
    }

    private func handle(_ message: PluginMessage) {
        let doc = LiveDocument(app: message.app,
                               path: message.payload.path,
                               name: message.payload.name)
        switch message.type {
        case .documentClosed:
            documents.removeAll { $0.id == doc.id }
        case .documentOpened, .documentSaved, .snapshotRequested:
            // A just-saved Untitled doc gains a real path: drop the stale
            // pathless entry for the same app+name so it isn't duplicated.
            if doc.hasFile {
                documents.removeAll { !$0.hasFile && $0.app == doc.app && $0.name == doc.name }
            }
            if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
                documents[idx] = doc
            } else {
                documents.append(doc)
            }
        }
    }
}
