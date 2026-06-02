import AppKit

/// Caches file icons for the lifetime of the app. Keyed by *type* (extension for
/// files, a single key for folders) so a directory full of same-type design files
/// only triggers one `NSWorkspace` lookup instead of one per file.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for item: DirectoryItem) async -> NSImage {
        let key = item.isDirectory ? "/dir" : item.url.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let path = item.path
        let image = await Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.icon(forFile: path)
        }.value
        cache[key] = image
        return image
    }
}
