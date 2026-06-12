import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// PureRef-style reference board for the selected file. A wide, pannable / zoomable
/// canvas you can drop or paste images onto, then drag and resize freely. Geometry
/// and the images themselves are persisted per file via `MoodboardStore`.
///
/// Interaction model: dragging on empty canvas draws a marquee (rubber-band) that
/// selects every item it touches; panning is done with the scroll wheel / trackpad
/// scroll instead. Dragging any selected item moves the whole selection together.
///
/// Unlike `CanvasView`, the content isn't wrapped in a `scaleEffect`: each item is
/// laid out directly in screen space from its board coordinates, the live pan, and
/// the zoom. That keeps item drag / resize translations in plain screen points, so
/// converting back to board space is a single divide by the scale.
struct MoodboardCanvas: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @EnvironmentObject var store: MoodboardStore

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @State private var selectedIDs: Set<String> = []
    /// Screen-space marquee rectangle while a rubber-band drag is in flight.
    @State private var marquee: CGRect? = nil
    /// Selection present when the marquee drag began (preserved on shift-drag).
    @State private var marqueeBaseSelection: Set<String> = []
    /// Live translation applied to every selected item during a group move.
    @State private var groupDragTranslation: CGSize = .zero
    /// Live scale factor applied to the selection during a resize, anchored at the
    /// selection's top-left corner. 1 when no resize is in flight.
    @State private var groupScaleFactor: CGFloat = 1.0
    /// Screen-space bounding box of the selection when the resize drag began.
    /// Its origin is the fixed anchor every selected item scales around.
    @State private var resizeStartBox: CGRect? = nil
    @FocusState private var focused: Bool

    private var boardKey: String? {
        directoryStore.selectedFile?.resolvingSymlinksInPath().path
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let effectiveScale = scale * gestureScale

            ZStack {
                // Background: marquee selection, tap-to-deselect, double-tap reset.
                // Items sit above it, so a drag that starts on an item never
                // reaches here — the marquee only starts on empty canvas.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture(canvasSize: geometry.size, scale: effectiveScale))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.35)) {
                            scale = 1.0
                            offset = .zero
                        }
                    }
                    .onTapGesture { selectedIDs = [] }

                ForEach(store.items) { item in
                    MoodboardItemView(
                        item: item,
                        canvasSize: geometry.size,
                        scale: effectiveScale,
                        offsetX: offset.width,
                        offsetY: offset.height,
                        isSelected: selectedIDs.contains(item.id),
                        groupTranslation: selectedIDs.contains(item.id) ? groupDragTranslation : .zero,
                        groupScale: selectedIDs.contains(item.id) ? groupScaleFactor : 1,
                        groupScaleAnchor: resizeStartBox?.origin ?? .zero,
                        onTap: { select(item.id, additive: isShiftDown) },
                        onDragBegan: {
                            // Dragging an unselected item makes it the selection
                            // (or joins it on shift) before the group move starts.
                            if !selectedIDs.contains(item.id) {
                                select(item.id, additive: isShiftDown)
                            }
                        },
                        onDragChanged: { groupDragTranslation = $0 },
                        onDragEnded: { translation in
                            commitGroupMove(translation, scale: effectiveScale)
                        }
                    )
                }

                if let marquee {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
                        .frame(width: marquee.width, height: marquee.height)
                        .position(x: marquee.midX, y: marquee.midY)
                        .allowsHitTesting(false)
                }

                // Selection bounding-box border + resize handle, tracking any
                // in-flight group move or resize. Hidden while a marquee drags.
                if marquee == nil,
                   let box = selectionBox(canvasSize: geometry.size, scale: effectiveScale) {
                    selectionOverlay(box: box, canvasSize: geometry.size, scale: effectiveScale)
                }

                if store.items.isEmpty {
                    emptyState
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .background(
                ScrollWheelCatcher { delta in
                    offset.width += delta.width
                    offset.height += delta.height
                }
            )
            .gesture(
                MagnifyGesture()
                    .updating($gestureScale) { value, state, _ in
                        state = value.magnification
                    }
                    .onEnded { value in
                        scale = max(0.1, scale * value.magnification)
                    }
            )
            .clipped()
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers, location in
                let point = boardPoint(for: location, canvasSize: geometry.size)
                handleDrop(providers, at: point)
                return true
            }
            .onPasteCommand(of: [.image, .fileURL]) { providers in
                let center = boardPoint(for: CGPoint(x: w / 2, y: h / 2), canvasSize: geometry.size)
                handleDrop(providers, at: center)
            }
            .onDeleteCommand {
                for id in selectedIDs { store.delete(id) }
                selectedIDs = []
            }
            .overlay(alignment: .bottomLeading) {
                addButton.padding(20)
            }
            .overlay(alignment: .bottomTrailing) {
                ZoomIndicator(scale: effectiveScale) { newScale in
                    withAnimation(.spring(duration: 0.35)) { scale = newScale }
                }
                .padding(20)
            }
            .task(id: boardKey) {
                selectedIDs = []
                store.load(key: boardKey)
                focused = true
            }
        }
    }

    // MARK: - Selection

    private var isShiftDown: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
    }

    private func select(_ id: String, additive: Bool) {
        if additive {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = [id]
            store.bringToFront(id)
        }
    }

    /// Rubber-band selection on the empty canvas. Selects every item whose screen
    /// rect intersects the marquee, live while dragging. Shift keeps the selection
    /// that existed at drag start and adds to it.
    private func marqueeGesture(canvasSize: CGSize, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if marquee == nil {
                    marqueeBaseSelection = isShiftDown ? selectedIDs : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                let hit = store.items
                    .filter { screenRect(for: $0, canvasSize: canvasSize, scale: scale).intersects(rect) }
                    .map(\.id)
                selectedIDs = marqueeBaseSelection.union(hit)
            }
            .onEnded { _ in
                marquee = nil
                marqueeBaseSelection = []
            }
    }

    /// Screen-space bounds of an item under the current pan / zoom.
    private func screenRect(for item: MoodboardItem, canvasSize: CGSize, scale: CGFloat) -> CGRect {
        let width = item.width * scale
        let height = item.height * scale
        let centerX = canvasSize.width / 2 + item.x * scale + offset.width
        let centerY = canvasSize.height / 2 + item.y * scale + offset.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// Persists a finished group move: every selected item shifts by the same
    /// translation, converted from screen points back to board points.
    private func commitGroupMove(_ translation: CGSize, scale: CGFloat) {
        groupDragTranslation = .zero
        let dx = translation.width / scale
        let dy = translation.height / scale
        for item in store.items where selectedIDs.contains(item.id) {
            store.move(item.id, to: CGPoint(x: item.x + dx, y: item.y + dy))
        }
    }

    // MARK: - Group resize

    /// Screen-space bounding box around all selected items (untransformed by any
    /// in-flight resize). `nil` when nothing is selected.
    private func selectionBox(canvasSize: CGSize, scale: CGFloat) -> CGRect? {
        let rects = store.items
            .filter { selectedIDs.contains($0.id) }
            .map { screenRect(for: $0, canvasSize: canvasSize, scale: scale) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Border around the whole selection plus its resize handle. Dragging the
    /// handle scales every selected item around the selection's *top-left*
    /// corner, which stays fixed. The border follows in-flight moves and resizes.
    @ViewBuilder
    private func selectionOverlay(box: CGRect, canvasSize: CGSize, scale: CGFloat) -> some View {
        // While resizing, grow the start box by the live factor about its origin;
        // while moving, shift the live box by the drag translation.
        let base = resizeStartBox ?? box
        let display = CGRect(
            x: base.minX + groupDragTranslation.width,
            y: base.minY + groupDragTranslation.height,
            width: base.width * groupScaleFactor,
            height: base.height * groupScaleFactor
        )

        RoundedRectangle(cornerRadius: MoodboardItemView.cornerRadius)
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: display.width, height: display.height)
            .position(x: display.midX, y: display.midY)
            .allowsHitTesting(false)

        // The handle hides during a group move — its drag would conflict.
        if groupDragTranslation == .zero {
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .contentShape(Rectangle().scale(2))
                .position(x: display.maxX, y: display.maxY)
                .highPriorityGesture(
                    DragGesture()
                        .onChanged { value in
                            if resizeStartBox == nil { resizeStartBox = box }
                            guard let start = resizeStartBox, start.width > 0 else { return }
                            let raw = (start.width + value.translation.width) / start.width
                            groupScaleFactor = max(minScaleFactor(), raw)
                        }
                        .onEnded { _ in
                            commitGroupResize(canvasSize: canvasSize, scale: scale)
                        }
                )
        }
    }

    /// Smallest allowed scale factor: no selected item may shrink below the
    /// store's minimum dimension on its shorter side.
    private func minScaleFactor() -> CGFloat {
        let smallestSide = store.items
            .filter { selectedIDs.contains($0.id) }
            .map { min($0.width, $0.height) }
            .min() ?? store.minItemDimension
        guard smallestSide > 0 else { return 1 }
        return store.minItemDimension / smallestSide
    }

    /// Persists a finished group resize: sizes scale by the factor, and centers
    /// move away from / toward the fixed top-left anchor by the same factor.
    private func commitGroupResize(canvasSize: CGSize, scale: CGFloat) {
        defer {
            resizeStartBox = nil
            groupScaleFactor = 1
        }
        guard let start = resizeStartBox else { return }
        let f = groupScaleFactor
        guard f != 1 else { return }
        let anchor = boardPoint(for: start.origin, canvasSize: canvasSize)
        for item in store.items where selectedIDs.contains(item.id) {
            store.resize(item.id, to: CGSize(width: item.width * f, height: item.height * f))
            store.move(item.id, to: CGPoint(
                x: anchor.x + (item.x - anchor.x) * f,
                y: anchor.y + (item.y - anchor.y) * f
            ))
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyState: some View {
        if boardKey == nil {
            messageStack(
                title: "No file selected",
                subtitle: "Select a design file in the sidebar to start a board"
            )
        } else {
            messageStack(
                title: "Drop images here",
                subtitle: "Drag & drop, paste (⌘V), or use ＋ to add references"
            )
        }
    }

    private func messageStack(title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(NSColor.tertiaryLabelColor))
            Text(title)
                .font(.body)
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Text(subtitle)
                .font(.callout)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .multilineTextAlignment(.center)
        }
    }

    private var addButton: some View {
        Button {
            importViaPanel()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(NSColor.labelColor))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(boardKey == nil)
        .opacity(boardKey == nil ? 0.4 : 1)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help("Add images to the board")
    }

    // MARK: - Geometry

    /// Converts a point in the canvas's own coordinate space (top-left origin) into
    /// board coordinates (center origin, unscaled). Uses the committed pan / zoom,
    /// which is correct for drop / paste since no live gesture is in flight then.
    private func boardPoint(for location: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: (location.x - offset.width - canvasSize.width / 2) / scale,
            y: (location.y - offset.height - canvasSize.height / 2) / scale
        )
    }

    // MARK: - Adding images

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) {
        guard boardKey != nil else { return }
        // Fan the drop out slightly so a multi-image drop doesn't fully overlap.
        for (index, provider) in providers.enumerated() {
            let dropPoint = CGPoint(x: point.x + CGFloat(index) * 24,
                                    y: point.y + CGFloat(index) * 24)
            Task {
                if let payload = await MoodboardImageLoader.decode(provider) {
                    store.addImage(data: payload.data, fileExtension: payload.ext, at: dropPoint)
                }
            }
        }
    }

    private func importViaPanel() {
        guard boardKey != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for (index, url) in panel.urls.enumerated() {
            guard let data = try? Data(contentsOf: url) else { continue }
            // Stagger imports around the board origin.
            let point = CGPoint(x: CGFloat(index) * 24, y: CGFloat(index) * 24)
            store.addImage(data: data, fileExtension: url.pathExtension, at: point)
        }
    }
}

/// A single image on the board. Lays itself out in screen space from its board
/// geometry plus the canvas pan / zoom. Moving and resizing are both delegated to
/// the canvas so a multi-selection moves and scales as one; this view only applies
/// the in-flight group transform (translation, or scale about the selection's
/// top-left anchor) to its own layout.
struct MoodboardItemView: View {
    @EnvironmentObject var store: MoodboardStore
    let item: MoodboardItem
    let canvasSize: CGSize
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let isSelected: Bool
    /// Live translation of the whole selection while a group move is in flight.
    let groupTranslation: CGSize
    /// Live scale of the whole selection while a group resize is in flight (1 when
    /// idle), anchored at `groupScaleAnchor` in screen space.
    let groupScale: CGFloat
    let groupScaleAnchor: CGPoint
    let onTap: () -> Void
    let onDragBegan: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    @State private var image: NSImage? = nil
    @State private var isDragging = false

    private var screenWidth: CGFloat { item.width * scale * groupScale }
    private var screenHeight: CGFloat { item.height * scale * groupScale }

    /// Center of the item on screen, including any in-flight group move or the
    /// group resize (which pushes centers away from the fixed top-left anchor).
    private var screenCenter: CGPoint {
        var center = CGPoint(
            x: canvasSize.width / 2 + item.x * scale + offsetX + groupTranslation.width,
            y: canvasSize.height / 2 + item.y * scale + offsetY + groupTranslation.height
        )
        if groupScale != 1 {
            center.x = groupScaleAnchor.x + (center.x - groupScaleAnchor.x) * groupScale
            center.y = groupScaleAnchor.y + (center.y - groupScaleAnchor.y) * groupScale
        }
        return center
    }

    /// Corner radius of every board image — the selection border reuses it so the
    /// outline hugs a single selected image exactly.
    static let cornerRadius: CGFloat = 4

    var body: some View {
        let cornerRadius = Self.cornerRadius
        ZStack {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color(NSColor.quaternaryLabelColor))
                }
            }
            .frame(width: screenWidth, height: screenHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .frame(width: screenWidth, height: screenHeight)
        .position(screenCenter)
        .gesture(moveGesture)
        .onTapGesture { onTap() }
        .task(id: item.filename) {
            let url = store.imageURL(for: item)
            image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onDragBegan()
                }
                onDragChanged(value.translation)
            }
            .onEnded { value in
                isDragging = false
                onDragEnded(value.translation)
            }
    }
}

/// Extracts decodable image bytes from a dropped or pasted `NSItemProvider`,
/// preferring an on-disk file (keeps the original encoding) and falling back to
/// raw image data registered on the provider.
enum MoodboardImageLoader {
    struct Payload {
        let data: Data
        let ext: String
    }

    static func decode(_ provider: NSItemProvider) async -> Payload? {
        // 1. A file on disk — read it directly so we keep the original bytes.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(provider),
           let data = try? Data(contentsOf: url),
           NSImage(data: data) != nil {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            return Payload(data: data, ext: ext)
        }

        // 2. Raw image data registered on the provider (e.g. a pasted screenshot).
        let types: [UTType] = [.png, .jpeg, .tiff, .gif, .heic, .bmp, .image]
        for type in types where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await loadData(provider, type.identifier), NSImage(data: data) != nil {
                return Payload(data: data, ext: type.preferredFilenameExtension ?? "png")
            }
        }
        return nil
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, _ typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
