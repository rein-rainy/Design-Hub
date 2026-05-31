import SwiftUI

@main
struct DesignHubApp: App {
    @StateObject private var pluginBridge = PluginBridgeServer()
    @StateObject private var versionStore: VersionStore = {
        (try? VersionStore.makeDefault()) ?? VersionStore(db: try! Database(path: ":memory:"))
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pluginBridge)
                .environmentObject(versionStore)
                .task {
                    pluginBridge.start()
                    versionStore.subscribe(to: pluginBridge)
                }
        }
    }
}
