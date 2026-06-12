import CoreGraphics
import Foundation

/// One image pinned to a moodboard. Geometry is stored in *board points* — an
/// untransformed coordinate space whose origin is the canvas center — so a board
/// renders identically regardless of the current pan / zoom. `x`/`y` are the
/// item's center offset from that origin; `width`/`height` are its size at 100%.
struct MoodboardItem: Identifiable, Equatable {
    let id: String
    /// The board this item belongs to — the resolved path of the selected file.
    var boardKey: String
    /// File name (not full path) under the store's images directory.
    var filename: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// Stacking order; higher draws on top.
    var z: Int
    var createdAt: Date
}
