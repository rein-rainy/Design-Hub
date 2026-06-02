import Foundation
import AppKit
import Combine
import SwiftUI

struct DirectoryGroup: Identifiable, Codable {
    let id: UUID
    let path: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }

    init(path: String) {
        self.id = UUID()
        self.path = path
    }
}

@MainActor
final class DirectoryGroupStore: ObservableObject {
    @Published private(set) var groups: [DirectoryGroup] = []
    @Published var selectedFile: URL? = nil

    // Expansion state is persisted but intentionally NOT @Published. Every row in
    // the tree holds this store via @EnvironmentObject, so publishing an expansion
    // change would re-render (and animate) the entire tree on every single toggle.
    // Each row instead drives its own expansion via local @State and writes back
    // here only for persistence.
    private(set) var expandedGroupIDs: Set<UUID> = []
    private(set) var expandedPaths: Set<String> = []

    private let groupsKey = "directoryGroups"
    private let expandedGroupsKey = "expandedGroupIDs"
    private let expandedPathsKey = "expandedPaths"
    private var saveExpansionTask: Task<Void, Never>?

    init() { load() }

    func openDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory to add as a group"
        panel.prompt = "Add Group"

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] resp in
                if resp == .OK, let url = panel.url {
                    self?.addGroup(at: url)
                }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url {
                addGroup(at: url)
            }
        }
    }

    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        expandedGroupIDs.remove(id)
        saveGroups()
        saveExpansionNow()
    }

    func isGroupExpanded(_ id: UUID) -> Bool { expandedGroupIDs.contains(id) }
    func isPathExpanded(_ path: String) -> Bool { expandedPaths.contains(path) }

    func setGroupExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { expandedGroupIDs.insert(id) } else { expandedGroupIDs.remove(id) }
        scheduleExpansionSave()
    }

    func setPathExpanded(_ path: String, _ expanded: Bool) {
        if expanded { expandedPaths.insert(path) } else { expandedPaths.remove(path) }
        scheduleExpansionSave()
    }

    private func scheduleExpansionSave() {
        saveExpansionTask?.cancel()
        saveExpansionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveExpansionNow()
        }
    }

    private func addGroup(at url: URL) {
        guard !groups.contains(where: { $0.path == url.path }) else { return }
        groups.append(DirectoryGroup(path: url.path))
        saveGroups()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let decoded = try? JSONDecoder().decode([DirectoryGroup].self, from: data) {
            groups = decoded
        }
        if let ids = UserDefaults.standard.array(forKey: expandedGroupsKey) as? [String] {
            expandedGroupIDs = Set(ids.compactMap { UUID(uuidString: $0) })
        }
        if let paths = UserDefaults.standard.array(forKey: expandedPathsKey) as? [String] {
            expandedPaths = Set(paths)
        }
    }

    private func saveGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: groupsKey)
    }

    private func saveExpansionNow() {
        UserDefaults.standard.set(expandedGroupIDs.map(\.uuidString), forKey: expandedGroupsKey)
        UserDefaults.standard.set(Array(expandedPaths), forKey: expandedPathsKey)
    }
}
