import SwiftUI

@main
struct DesignHubApp: App {
    @StateObject private var pluginBridge = PluginBridgeServer()
    @StateObject private var versionStore: VersionStore = {
        (try? VersionStore.makeDefault()) ?? VersionStore(db: try! Database(path: ":memory:"))
    }()
    @StateObject private var directoryGroupStore = DirectoryGroupStore()
    @StateObject private var liveDocumentStore = LiveDocumentStore()
    @StateObject private var moodboardStore: MoodboardStore = {
        (try? MoodboardStore.makeDefault())
            ?? MoodboardStore(
                db: try! Database(path: ":memory:"),
                imagesDir: FileManager.default.temporaryDirectory
            )
    }()
    @State private var coordinator = AppCoordinator()
    @State private var saveWatcher = DocumentSaveWatcher()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pluginBridge)
                .environmentObject(versionStore)
                .environmentObject(directoryGroupStore)
                .environmentObject(liveDocumentStore)
                .environmentObject(moodboardStore)
                .task {
                    AutoSaveNotifier.requestAuthorization()
                    pluginBridge.start()
                    versionStore.subscribe(to: pluginBridge)
                    versionStore.subscribeToDebugSimulation()
                    liveDocumentStore.subscribe(to: pluginBridge)
                    saveWatcher.subscribe(to: liveDocumentStore, bridge: pluginBridge)
                    // An auto-save writes the .ai file from our own request;
                    // mute the watcher so that write isn't seen as a user save.
                    versionStore.onAutoSaveRequested = { [weak saveWatcher] in
                        saveWatcher?.suppress(for: 20)
                    }
                    coordinator.bind(to: versionStore)
                }
        }
        .commands {
            CommandMenu("Debug") {
                Button("Simulate File Save") {
                    NotificationCenter.default.post(name: .simulateFileSave, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Simulate Auto-save Now") {
                    NotificationCenter.default.post(name: .simulateAutoSaveNow, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }
        }
    }
}
