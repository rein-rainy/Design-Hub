import AppKit
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
    // Kept separate from `cancellables` so re-subscribing to a bridge doesn't tear
    // down the OS-level termination watcher.
    private var terminationObserver: AnyCancellable?

    init() {
        // A plugin can't always send `document_closed` for every open document when
        // its host app quits or crashes (or the bridge connection just drops). Watch
        // the OS for Photoshop/Illustrator terminating and clear that app's documents
        // so "Now Editing" can never show entries for an app that's no longer running.
        terminationObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .compactMap { Self.appSource(for: $0) }
            .sink { [weak self] app in
                self?.documents.removeAll { $0.app == app }
            }
    }

    func subscribe(to bridge: PluginBridgeServer) {
        cancellables.removeAll()
        bridge.messagePublisher
            .sink { [weak self] message in self?.handle(message) }
            .store(in: &cancellables)
    }

    /// Maps a terminated running application to the design app it represents,
    /// matching on the bundle identifier so version suffixes don't matter.
    /// Adobe spawns helper processes whose bundle IDs also contain the app name,
    /// so we only treat the main GUI app (a `.regular` app) as the host quitting —
    /// otherwise a helper dying would wipe a still-open document from "Now Editing".
    private static func appSource(for app: NSRunningApplication) -> PluginMessage.AppSource? {
        guard app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier?.lowercased() else { return nil }
        if bundleID.contains("photoshop") { return .photoshop }
        if bundleID.contains("illustrator") { return .illustrator }
        return nil
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
