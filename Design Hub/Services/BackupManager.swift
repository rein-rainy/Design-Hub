import Foundation

/// Handles the on-disk file copies behind each commit: backing up the saved
/// document into the app's object store, and restoring a backup as a sibling
/// of the original file. All paths are plain filesystem paths; virtual paths
/// (e.g. "photoshop://Untitled.psd") are rejected by the caller.
enum BackupManager {

    /// Filename-safe timestamp (e.g. "2026-06-02_153000") used to name restored files.
    private static let restoreTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    static func backupDirectory(for projectID: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DesignHub/objects/\(projectID)", isDirectory: true)
    }

    /// Copies `sourcePath` into the project's object store, named by commit id.
    /// Returns the backup path, or nil if there was nothing to back up / it failed.
    static func backup(sourcePath: String, commitID: String, projectID: String) -> String? {
        guard !sourcePath.isEmpty else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { return nil }

        let ext = URL(fileURLWithPath: sourcePath).pathExtension
        let destDir = backupDirectory(for: projectID)
        let destPath = destDir.appendingPathComponent("\(commitID).\(ext)").path

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: sourcePath, toPath: destPath)
            return destPath
        } catch {
            print("[BackupManager] Backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Restores `backupPath` as a sibling of `originalURL`, named
    /// `<name>_restored_<timestamp>.<ext>`. Never overwrites the original.
    /// Returns the URL written, or nil on failure.
    static func restore(backupPath: String, originalURL: URL, timestamp: Date) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else {
            print("[BackupManager] Restore failed — backup file missing")
            return nil
        }

        let directory = originalURL.deletingLastPathComponent()
        let ext = originalURL.pathExtension
        let baseName = originalURL.deletingPathExtension().lastPathComponent

        let stamp = restoreTimestampFormatter.string(from: timestamp)
        var candidate = directory.appendingPathComponent(
            ext.isEmpty ? "\(baseName)_restored_\(stamp)" : "\(baseName)_restored_\(stamp).\(ext)"
        )

        // Avoid clobbering an existing restore from the same commit timestamp.
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty
                ? "\(baseName)_restored_\(stamp)_\(counter)"
                : "\(baseName)_restored_\(stamp)_\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }

        do {
            try fm.copyItem(at: URL(fileURLWithPath: backupPath), to: candidate)
            print("[BackupManager] Restored backup → \(candidate.path)")
            return candidate
        } catch {
            print("[BackupManager] Restore failed: \(error.localizedDescription)")
            return nil
        }
    }
}
