import Foundation
import QuickLookThumbnailing
import AppKit

enum ThumbnailGenerator {

    /// Generates a JPEG thumbnail from any file QuickLook supports (PSD, AI, PNG, …).
    /// Saves it as a .jpg next to the source file and returns the output URL.
    static func generate(from fileURL: URL,
                         size: CGSize = CGSize(width: 400, height: 400)) async -> URL? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: 2.0,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateRepresentations(for: request) { rep, _, error in
                guard let rep, error == nil else {
                    print("[Thumbnail] Failed for \(fileURL.lastPathComponent): \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                    return
                }

                let outputURL = fileURL.deletingPathExtension().appendingPathExtension("jpg")
                let image = rep.nsImage

                guard
                    let tiff   = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let jpeg   = bitmap.representation(using: .jpeg,
                                                       properties: [.compressionFactor: NSNumber(value: 0.85)])
                else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    try jpeg.write(to: outputURL)
                    continuation.resume(returning: outputURL)
                } catch {
                    print("[Thumbnail] Write failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Renders a high-resolution NSImage from a QuickLook-compatible file (PSD, AI, PNG, …).
    /// Does not write to disk — returns the image directly for canvas display.
    static func renderHiRes(from fileURL: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: 1.0,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
                guard let rep, error == nil else {
                    print("[Thumbnail] HiRes failed for \(fileURL.lastPathComponent): \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: rep.nsImage)
            }
        }
    }
}
