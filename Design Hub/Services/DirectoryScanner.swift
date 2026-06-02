import Foundation

/// File extensions Design Hub can preview/track in the directory tree.
nonisolated let previewableExtensions: Set<String> = [
    "png","jpg","jpeg","gif","webp","tiff","tif","bmp","heic","psd","ai","pdf"
]

/// A directory entry whose `isDirectory` / `isPreviewable` flags are resolved
/// once at load time, so the render path never touches the filesystem.
struct DirectoryItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let isPreviewable: Bool

    nonisolated var id: String { url.path }
    nonisolated var path: String { url.path }
    nonisolated var name: String { url.lastPathComponent }
}

/// Reads, filters and sorts a directory's contents. Pure & `nonisolated` so it
/// can run off the main thread; resolves `.isDirectoryKey` exactly once per item.
nonisolated func loadDirectoryItems(at url: URL) -> [DirectoryItem] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let items = contents.compactMap { child -> DirectoryItem? in
        let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            // Hide directories that contain no previewable content anywhere.
            guard directoryHasVisibleContent(child) else { return nil }
            return DirectoryItem(url: child, isDirectory: true, isPreviewable: false)
        }
        guard previewableExtensions.contains(child.pathExtension.lowercased()) else { return nil }
        return DirectoryItem(url: child, isDirectory: false, isPreviewable: true)
    }

    return items.sorted { a, b in
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Whether a directory (recursively) contains at least one previewable file.
/// Checks direct files first, then descends; early-exits on the first hit, so for
/// real design folders it returns almost immediately. `nonisolated` for off-main use.
nonisolated func directoryHasVisibleContent(_ url: URL) -> Bool {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return false }

    var subdirectories: [URL] = []
    for child in contents {
        let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            subdirectories.append(child)
        } else if previewableExtensions.contains(child.pathExtension.lowercased()) {
            return true
        }
    }
    for subdirectory in subdirectories where directoryHasVisibleContent(subdirectory) {
        return true
    }
    return false
}
