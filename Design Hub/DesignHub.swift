import SwiftUI

@main
struct DesignHubApp: App {
    @StateObject private var pluginBridge = PluginBridgeServer()
    @StateObject private var versionStore: VersionStore = {
        (try? VersionStore.makeDefault()) ?? VersionStore(db: try! Database(path: ":memory:"))
    }()
    @StateObject private var directoryGroupStore = DirectoryGroupStore()
    @StateObject private var liveDocumentStore = LiveDocumentStore()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pluginBridge)
                .environmentObject(versionStore)
                .environmentObject(directoryGroupStore)
                .environmentObject(liveDocumentStore)
                .task {
                    AutoSaveNotifier.requestAuthorization()
                    pluginBridge.start()
                    versionStore.subscribe(to: pluginBridge)
                    versionStore.subscribeToDebugSimulation()
                    liveDocumentStore.subscribe(to: pluginBridge)
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
