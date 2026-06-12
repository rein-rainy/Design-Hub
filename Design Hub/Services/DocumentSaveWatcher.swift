import Foundation
import Combine

/// Watches the on-disk files of documents open in Illustrator and asks the
/// plugin for a fresh snapshot when one changes — i.e. when the user saves.
///
/// Save detection used to live in the CEP panel, which polled ExtendScript
/// every 1.5 s; each evalScript runs on Illustrator's main thread and
/// interrupted the user's tools. Watching the file from this side detects a
/// save instantly without ever touching Illustrator.
@MainActor
final class DocumentSaveWatcher {

    private var watchers: [String: FileWatcher] = [:]   // path → watcher
    private var cancellables = Set<AnyCancellable>()
    private weak var bridge: PluginBridgeServer?
    private var suppressedUntil: Date = .distantPast

    func subscribe(to liveStore: LiveDocumentStore, bridge: PluginBridgeServer) {
        self.bridge = bridge
        cancellables.removeAll()
        liveStore.$documents
            .sink { [weak self] docs in self?.sync(with: docs) }
            .store(in: &cancellables)
    }

    /// Ignore file changes for a window of time. Used around programmatic
    /// auto-saves (which write the file from our own request_snapshot) so they
    /// don't masquerade as user saves and pop the commit panel.
    func suppress(for interval: TimeInterval) {
        suppressedUntil = Date().addingTimeInterval(interval)
    }

    private func sync(with docs: [LiveDocument]) {
        // Photoshop's UXP plugin detects saves itself via host events;
        // only Illustrator documents need file watching. Untitled documents
        // have no file on disk to watch.
        let paths = Set(docs.filter { $0.app == .illustrator && $0.hasFile }.map(\.path))

        for path in watchers.keys where !paths.contains(path) {
            watchers.removeValue(forKey: path)?.cancel()
        }
        for path in paths where watchers[path] == nil {
            watchers[path] = FileWatcher(path: path) { [weak self] in
                self?.fileChanged()
            }
        }
    }

    private func fileChanged() {
        guard Date() >= suppressedUntil else { return }
        bridge?.requestSaveSnapshot()
    }
}

/// Watches a single file via DispatchSource. Illustrator saves atomically
/// (write temp → rename over the original), which makes the watched vnode
/// disappear, so the watcher re-arms itself on delete/rename. Bursts of write
/// events from one save are debounced into a single callback.
@MainActor
private final class FileWatcher {

    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var cancelled = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    func cancel() {
        cancelled = true
        debounceTask?.cancel()
        source?.cancel()
        source = nil
    }

    private func arm() {
        guard !cancelled else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-atomic-save the path can be momentarily absent — retry.
            rearm(after: .milliseconds(500))
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.handleEvent() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func handleEvent() {
        guard let src = source else { return }
        if !src.data.intersection([.delete, .rename]).isEmpty {
            // File replaced by an atomic save — the old vnode is dead.
            src.cancel()
            source = nil
            rearm(after: .milliseconds(300))
        }
        scheduleChange()
    }

    private func rearm(after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.arm()
        }
    }

    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, !self.cancelled else { return }
            self.onChange()
        }
    }
}
