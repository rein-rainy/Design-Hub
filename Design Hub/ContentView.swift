import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case single = "Single"
    case compare = "Compare"
    case slider = "Slider"

    var id: String { rawValue }
}

/// Top-level workspace mode. `versions` is the existing commit/preview workspace;
/// `moodboard` is the upcoming PureRef-style per-project reference board.
enum AppMode: String, CaseIterable, Identifiable {
    case versions = "Versions"
    case moodboard = "Moodboard"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .versions: return "clock.arrow.circlepath"
        case .moodboard: return "square.grid.2x2"
        }
    }
}

/// Top-level shell: just the split view. It holds no volatile per-view state, so
/// switching modes or zooming the canvas never re-evaluates this body — and the
/// left sidebar is left untouched. Detail-side state lives in `DetailView`.
struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            LeftSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 230)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

/// The detail column: owns the app mode, the inspector, and the
/// sidebar-selected commit (shared between the canvas and the inspector).
/// Canvas-only state (zoom / view mode) is isolated further down in
/// `VersionsCanvas`, so zooming never re-evaluates this body — keeping the
/// right-hand inspector from re-rendering.
struct DetailView: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @EnvironmentObject var versionStore: VersionStore
    @State private var appMode: AppMode = .versions
    @State private var isInspectorPresented: Bool = true
    @State private var selectedCommit: Commit? = nil
    @State private var showRestoreError: Bool = false
    /// Last user-set inspector width, fed back as the column's `ideal`. With a
    /// constant ideal, hiding the inspector first snapped a user-widened column
    /// back to the ideal width before the close animation — a visible jolt.
    @State private var inspectorWidth: CGFloat = 300

    /// Selected file name, shown as the plain window title.
    private var fileTitle: String {
        directoryStore.selectedFile?.lastPathComponent ?? ""
    }

    var body: some View {
        Group {
            switch appMode {
            case .versions:
                VersionsCanvas(selectedCommit: $selectedCommit)
            case .moodboard:
                MoodboardCanvas()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The inspector belongs to the Versions workspace only — hide it entirely
        // in Moodboard mode while preserving the user's show/hide preference.
        .inspector(isPresented: Binding(
            get: { appMode == .versions && isInspectorPresented },
            // Only record the user's preference while in Versions. In Moodboard the
            // inspector is force-hidden, and the framework's write-back of `false`
            // must not clobber the remembered show/hide state.
            set: { newValue in
                if appMode == .versions { isInspectorPresented = newValue }
            }
        )) {
            RightSidebar(selectedCommit: $selectedCommit)
                .inspectorColumnWidth(min: 240, ideal: inspectorWidth, max: 400)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    // Record only while fully shown — the collapse animation also
                    // streams shrinking widths, which must not become the ideal.
                    if appMode == .versions && isInspectorPresented && width >= 240 {
                        inspectorWidth = width
                    }
                }
        }
        // Show the selected file name as the plain window title (leading). Using
        // the title rather than a toolbar item keeps it as plain text instead of
        // getting macOS 26's automatic glass-capsule treatment.
        .navigationTitle(fileTitle)
        .toolbar {
            // Center: Versions / Moodboard switcher (system segmented picker).
            ToolbarItem(placement: .principal) {
                AppModeSwitcher(appMode: $appMode)
            }
            // Right side: revert (when a version is selected) then inspector toggle.
            if appMode == .versions, let commit = selectedCommit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        restore(commit)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Restore this version as a new file next to the original")
                }
            }
            // Always present (just disabled in Moodboard): removing the item
            // entirely re-laid-out the toolbar and made the mode switch jitter.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .disabled(appMode != .versions)
                .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .onChange(of: directoryStore.selectedFile) { _ in
            selectedCommit = nil
        }
        .alert("Restore Failed", isPresented: $showRestoreError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This version could not be restored. The backup or original file may be missing, or the file was never saved to disk.")
        }
    }

    private func restore(_ commit: Commit) {
        if let url = versionStore.restore(commit: commit) {
            // Reveal the freshly restored file in Finder so it's easy to find.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            showRestoreError = true
        }
    }
}

/// The Versions workspace canvas plus its floating mode switcher and zoom
/// indicator. Zoom (`canvasScale`) and `selectedMode` live here so changing them
/// only re-evaluates this view — not the inspector or the sidebars.
struct VersionsCanvas: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @Binding var selectedCommit: Commit?
    @State private var selectedMode: ViewMode = .single
    @State private var canvasScale: CGFloat = 1.0

    var body: some View {
        CanvasView(scale: $canvasScale, selectedMode: selectedMode, selectedCommit: selectedCommit)
            .overlay(alignment: .bottomLeading) {
                ViewModeSwitcher(selectedMode: $selectedMode)
                    .padding(20)
            }
            .overlay(alignment: .bottomTrailing) {
                ZoomIndicator(scale: canvasScale) { newScale in
                    withAnimation(.spring(duration: 0.35)) {
                        canvasScale = newScale
                    }
                }
                .padding(20)
            }
            .onChange(of: directoryStore.selectedFile) { _ in
                selectedMode = .single
            }
    }
}

struct CanvasView: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @EnvironmentObject var versionStore: VersionStore
    @Binding var scale: CGFloat
    let selectedMode: ViewMode
    let selectedCommit: Commit?
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize = .zero
    @State private var displayImage: NSImage? = nil
    // Slider-compare layers: base = latest commit, top = sidebar-selected commit.
    @State private var sliderBaseImage: NSImage? = nil
    @State private var sliderTopImage: NSImage? = nil
    // Split position as a fraction (0…1) of the canvas width.
    @State private var split: CGFloat = 0.5
    @State private var dragStartSplit: CGFloat? = nil

    private func resolvedPath(_ path: String) -> String {
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return url.resolvingSymlinksInPath().path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private var project: Project? {
        guard let file = directoryStore.selectedFile else { return nil }
        let target = resolvedPath(file.path)
        return versionStore.projects.first { resolvedPath($0.path) == target }
    }

    /// Newest commit for the current project (commits are stored newest-first).
    private var latestCommit: Commit? {
        guard let p = project else { return nil }
        return versionStore.commits(forProjectID: p.id).first
    }

    /// True once slider mode is active and both images have loaded.
    private var isSliding: Bool {
        selectedMode == .slider && sliderBaseImage != nil && sliderTopImage != nil
    }

    /// True once side-by-side compare mode is active and both images have loaded.
    private var isComparing: Bool {
        selectedMode == .compare && sliderBaseImage != nil && sliderTopImage != nil
    }

    private var taskID: String {
        let latest = latestCommit?.id ?? "-"
        let selected = selectedCommit?.id ?? "-"
        let file = directoryStore.selectedFile?.path ?? "-"
        return "\(selectedMode.rawValue)|latest:\(latest)|sel:\(selected)|file:\(file)"
    }

    /// One image at canvas size, no transform (transform is applied to the whole
    /// comparison assembly so the split line and clip can ride along with it).
    @ViewBuilder
    private func imageContent(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .scaledToFit()
            .padding(20)
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            // Split position in the image's own (untransformed) coordinate space.
            let localSplitX = max(0, min(w, split * w))
            let effectiveScale = scale * gestureScale
            let effectiveOffsetX = offset.width + gestureOffset.width
            let effectiveOffsetY = offset.height + gestureOffset.height
            // Where that split lands on screen once the assembly is scaled (about
            // the center) and offset — so the handle tracks the image content.
            let screenSplitX = (localSplitX - w / 2) * effectiveScale + w / 2 + effectiveOffsetX
            Color.clear
                .overlay {
                    Group {
                        if isSliding, let base = sliderBaseImage, let top = sliderTopImage {
                            ZStack {
                                // Left half: selected commit, clipped to [0, splitX].
                                imageContent(top)
                                    .frame(width: w, height: h)
                                    .mask(alignment: .leading) {
                                        Rectangle().frame(width: localSplitX)
                                    }
                                // Right half: latest commit, clipped to [splitX, width].
                                imageContent(base)
                                    .frame(width: w, height: h)
                                    .mask(alignment: .trailing) {
                                        Rectangle().frame(width: w - localSplitX)
                                    }
                            }
                            .frame(width: w, height: h)
                        } else if isComparing, let base = sliderBaseImage, let top = sliderTopImage {
                            // Side by side: selected commit (left) | latest commit (right).
                            HStack(spacing: 0) {
                                imageContent(top)
                                    .frame(width: w / 2, height: h)
                                imageContent(base)
                                    .frame(width: w / 2, height: h)
                            }
                            .frame(width: w, height: h)
                        } else if let img = displayImage {
                            imageContent(img)
                        }
                    }
                    .scaleEffect(effectiveScale)
                    .offset(x: effectiveOffsetX, y: effectiveOffsetY)
                }
                .overlay {
                    if isSliding {
                        SliderHandle(
                            screenX: screenSplitX,
                            canvasWidth: w,
                            canvasHeight: h,
                            scale: effectiveScale,
                            split: $split,
                            dragStartSplit: $dragStartSplit
                        )
                    }
                }
                .contentShape(Rectangle())
                .background(
                    ScrollWheelCatcher { delta in
                        offset.width += delta.width
                        offset.height += delta.height
                    }
                )
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .updating($gestureScale) { value, state, _ in
                                state = value.magnification
                            }
                            .onEnded { value in
                                scale *= value.magnification
                            },
                        DragGesture()
                            .updating($gestureOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                            }
                    )
                )
                .onTapGesture {
                    withAnimation(.spring(duration: 0.35)) {
                        scale = 1.0
                        offset = .zero
                    }
                }
                .clipped()
                .task(id: taskID) {
                    await loadImage(canvasSize: geometry.size)
                }
        }
    }

    private func loadImage(canvasSize: CGSize) async {
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let renderSize = CGSize(
            width: canvasSize.width * screenScale,
            height: canvasSize.height * screenScale
        )

        // Slider / Compare modes: latest commit vs the sidebar-selected one.
        if selectedMode == .slider || selectedMode == .compare,
           let latest = latestCommit, let latestPath = latest.backupPath,
           let selected = selectedCommit, let selectedPath = selected.backupPath {
            async let base = ThumbnailGenerator.renderHiRes(
                from: URL(fileURLWithPath: latestPath), size: renderSize)
            async let top = ThumbnailGenerator.renderHiRes(
                from: URL(fileURLWithPath: selectedPath), size: renderSize)
            let (baseImage, topImage) = await (base, top)
            guard !Task.isCancelled else { return }
            sliderBaseImage = baseImage
            sliderTopImage = topImage
            split = 0.5
            return
        }

        // Single-image modes (or slider with nothing to compare yet).
        sliderBaseImage = nil
        sliderTopImage = nil

        if let commit = selectedCommit {
            guard let backupPath = commit.backupPath else { return }
            let fileURL = URL(fileURLWithPath: backupPath)
            if let image = await ThumbnailGenerator.renderHiRes(from: fileURL, size: renderSize) {
                guard !Task.isCancelled else { return }
                displayImage = image
            }
        } else if let fileURL = directoryStore.selectedFile {
            if let image = await ThumbnailGenerator.renderHiRes(from: fileURL, size: renderSize) {
                guard !Task.isCancelled else { return }
                displayImage = image
            }
        } else {
            displayImage = nil
        }
    }
}

/// The draggable vertical divider for slider-compare mode: a thin line with a
/// round grab handle at its center. Dragging anywhere on the strip moves the split.
struct SliderHandle: View {
    /// Screen-space x where the split currently lands (already transformed).
    let screenX: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    /// Effective zoom factor, so a screen-space drag maps back to local split.
    let scale: CGFloat
    @Binding var split: CGFloat
    @Binding var dragStartSplit: CGFloat?

    private let hitWidth: CGFloat = 44

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
            Circle()
                .fill(Color.white)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(NSColor.darkGray))
                }
        }
        .frame(width: hitWidth, height: canvasHeight)
        .contentShape(Rectangle())
        .position(x: screenX, y: canvasHeight / 2)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStartSplit ?? split
                    if dragStartSplit == nil { dragStartSplit = split }
                    // Screen drag → local fraction: undo the zoom factor.
                    let delta = value.translation.width / max(canvasWidth * scale, 1)
                    split = min(1, max(0, start + delta))
                }
                .onEnded { _ in dragStartSplit = nil }
        )
    }
}

struct ZoomIndicator: View {
    let scale: CGFloat
    let onSelect: (CGFloat) -> Void

    private var percent: Int {
        Int((scale * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(percent)%")
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .contentTransition(.numericText(value: Double(percent)))
                .animation(.snappy(duration: 0.25), value: percent)
            Divider()
            Menu {
                Button("25%") { onSelect(0.25) }
                Button("50%") { onSelect(0.5) }
                Button("75%") { onSelect(0.75) }
                Button("100%") { onSelect(1.0) }
                Button("125%") { onSelect(1.25) }
                Button("150%") { onSelect(1.5) }
                Button("175%") { onSelect(1.75) }
                Button("200%") { onSelect(2.0) }
                Button("250%") { onSelect(2.5) }
                Button("300%") { onSelect(3.0) }
                Button("350%") { onSelect(3.5) }
                Button("400%") { onSelect(4.0) }
            } label: {
                Image(systemName: "chevron.down")
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 22)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollWheelNSView)?.onScroll = onScroll
    }
}

private final class ScrollWheelNSView: NSView {
    var onScroll: ((CGSize) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        guard window != nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window == window else { return event }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            self.onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            return nil
        }
    }
}

/// Versions / Moodboard switcher — the system segmented picker (text only),
/// centered in the header.
struct AppModeSwitcher: View {
    @Binding var appMode: AppMode

    var body: some View {
        Picker("Mode", selection: $appMode) {
            ForEach(AppMode.allCases) { mode in
                // Pad "Moodboard" with two spaces each side so its segment isn't
                // visually cramped next to "Versions".
                Text(mode == .moodboard ? "  \(mode.rawValue)  " : mode.rawValue)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

/// Floating Single / Compare / Slider switcher, in a liquid-glass capsule. Pinned
/// at the bottom-left of the canvas.
struct ViewModeSwitcher: View {
    @Binding var selectedMode: ViewMode

    var body: some View {
        HStack(spacing: 15) {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    Image(mode.rawValue)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(mode == selectedMode
                    ? Color(NSColor.labelColor)
                    : Color(NSColor.secondaryLabelColor))
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct LeftSidebar: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @State private var isFloating: Bool = false
    @State private var canFadeTop: Bool = false
    @State private var floatingBtnHeight: CGFloat = 51

    private let btnPaddingH: CGFloat = 15
    private let btnPaddingBottom: CGFloat = 16
    private let floatingGapTop: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeatmapSection()
                .padding([.top, .horizontal], 15)
                .padding(.bottom, 20)

            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                        DirectoryTreeSection()
                        // インラインボタン: レイアウト内に常駐させてアニメーションに乗る
                        newGroupButton
                            .padding(.bottom, btnPaddingBottom)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(isFloating ? 0 : 1)
                    }
                    .padding(.horizontal, btnPaddingH)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 1
                } action: { _, newValue in
                    withAnimation(.snappy(duration: 0.2)) { isFloating = newValue }
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y > 0.5
                } action: { _, newValue in
                    withAnimation(.easeInOut(duration: 0.2)) { canFadeTop = newValue }
                }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: canFadeTop ? [.clear, .black] : [.black, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        Color.black
                        LinearGradient(
                            colors: isFloating ? [.black, .clear] : [.black, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        Color.clear.frame(height: isFloating ? floatingBtnHeight : 0)
                    }
                }

                // フローティングボタン: コンテンツがはみ出た時だけ表示
                if isFloating {
                    newGroupButton
                        .padding(.horizontal, btnPaddingH)
                        .padding(.top, floatingGapTop)
                        .padding(.bottom, btnPaddingBottom)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { geo in geo.size.height } action: {
                            if $0 > 0 { floatingBtnHeight = $0 }
                        }
                        .transition(.opacity.animation(.easeIn(duration: 0.15)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var newGroupButton: some View {
        Button {
            directoryStore.openDirectoryPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                Text("New Group")
                    .font(.callout)
            }
        }
        .buttonStyle(.plain)
    }
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

struct RightSidebar: View {
    @EnvironmentObject var versionStore: VersionStore
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @Binding var selectedCommit: Commit?
    @State private var canFadeTop: Bool = false
    @State private var canFadeBottom: Bool = false

    private var project: Project? {
        guard let file = directoryStore.selectedFile else { return nil }
        let target = resolvedPath(file.path)
        return versionStore.projects.first(where: { resolvedPath($0.path) == target })
    }

    private func resolvedPath(_ path: String) -> String {
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return url.resolvingSymlinksInPath().path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private var commits: [Commit] {
        guard let p = project else { return [] }
        return versionStore.commits(forProjectID: p.id)
    }

    private var autoSaveNumbers: [String: Int] {
        var result: [String: Int] = [:]
        var counter = 1
        for commit in commits.sorted(by: { $0.timestamp < $1.timestamp }) where commit.isAutosave {
            result[commit.id] = counter
            counter += 1
        }
        return result
    }

    private var dayGroups: [CommitDayGroup] {
        CommitGrouping.byDay(commits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Commits")
                    .font(.headline)
                Spacer()
                Text("\(commits.count) Commits")
                    .font(.footnote)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .padding(15)

            if directoryStore.selectedFile == nil {
                VStack(spacing: 6) {
                    Text("No file selected")
                        .font(.body)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    Text("Select a design file in the sidebar")
                        .font(.callout)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                VStack(spacing: 6) {
                    Text("No commits yet")
                        .font(.body)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    Text("Save a file in Photoshop or Illustrator\nto create a commit")
                        .font(.callout)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dayGroups) { group in
                            CommitDaySection(group: group, selectedCommit: $selectedCommit, autoSaveNumbers: autoSaveNumbers)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.bottom, 50)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y > 0.5
                } action: { _, newValue in
                    withAnimation(.easeInOut(duration: 0.2)) { canFadeTop = newValue }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 0.5
                } action: { _, newValue in
                    withAnimation(.easeInOut(duration: 0.25)) { canFadeBottom = newValue }
                }
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: canFadeTop ? [.clear, .black] : [.black, .black],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 20)
                        Color.black
                        LinearGradient(
                            colors: canFadeBottom ? [.black, .clear] : [.black, .black],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 20)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Chunks a flat commit list into user commits and consecutive autosave groups.
struct CommitDaySection: View {
    let group: CommitDayGroup
    @Binding var selectedCommit: Commit?
    let autoSaveNumbers: [String: Int]
    @State private var expandedGroups: Set<String> = []

    private var chunked: [CommitListItem] { CommitGrouping.chunkByAutosave(group.commits) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .stroke(Color(NSColor.secondaryLabelColor), lineWidth: 1)
                    .frame(width: 8, height: 8)
                Text(group.label)
                    .font(.body)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            HStack(alignment: .top, spacing: 10) {
                Divider().padding(.horizontal, 4)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chunked) { item in
                        switch item {
                        case .single(let commit):
                            CommitItemView(
                                commit: commit,
                                selectedCommit: $selectedCommit
                            )
                        case .autosaveGroup(let gid, let commits):
                            AutosaveGroupRow(
                                commits: commits,
                                isExpanded: expandedGroups.contains(gid),
                                selectedCommit: $selectedCommit,
                                autoSaveNumbers: autoSaveNumbers
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedGroups.contains(gid) {
                                        expandedGroups.remove(gid)
                                    } else {
                                        expandedGroups.insert(gid)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AutosaveGroupRow: View {
    let commits: [Commit]
    let isExpanded: Bool
    @Binding var selectedCommit: Commit?
    let autoSaveNumbers: [String: Int]
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                        .frame(width: 8)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    Text("\(commits.count) autosave versions")
                        .font(.body)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
            }
            .buttonStyle(.plain)
            if isExpanded {
                HStack(alignment: .top, spacing: 10) {
                    Divider().padding(.horizontal, 4)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(commits) { commit in
                            CommitItemView(
                                commit: commit,
                                selectedCommit: $selectedCommit,
                                autoSaveIndex: autoSaveNumbers[commit.id]
                            )
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

struct CommitItemView: View {
    @EnvironmentObject var versionStore: VersionStore
    let commit: Commit
    @Binding var selectedCommit: Commit?
    var autoSaveIndex: Int? = nil
    @State private var thumbnail: NSImage? = nil
    @State private var showRename = false
    @State private var draftMessage = ""
    @State private var showDeleteConfirm = false
    @State private var showRestoreError = false

    private var isSelected: Bool { selectedCommit?.id == commit.id }

    private func restore() {
        if let url = versionStore.restore(commit: commit) {
            // Reveal the freshly restored file in Finder so it's easy to find.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            showRestoreError = true
        }
    }

    private var timeLabel: String {
        relativeFormatter.localizedString(for: commit.timestamp, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(timeLabel)
                        .font(.callout)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    let badge = ChangeBadge.counts(shapeChange: commit.shapeChange, layerDiff: commit.layerDiff)
                    if badge.added > 0 || badge.removed > 0 {
                        HStack(spacing: 6) {
                            if badge.added > 0 {
                                Text("+\(badge.added)")
                                    .foregroundColor(Color(NSColor.systemGreen))
                            }
                            if badge.removed > 0 {
                                Text("-\(badge.removed)")
                                    .foregroundColor(Color(NSColor.systemRed))
                            }
                        }
                        .font(.callout.monospaced())
                    }
                }
                Text(commit.message.isEmpty
                    ? (autoSaveIndex.map { "Auto-save \($0)" } ?? "No message")
                    : commit.message)
                    .font(.body)
            }
            Spacer(minLength: 8)
            Group {
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.quinaryLabel))
                        .frame(width: 36, height: 36)
                        .overlay {
                            if commit.hasBackup && !commit.hasThumbnail {
                                ProgressView().scaleEffect(0.5)
                            }
                        }
                }
            }
            .frame(width: 36, height: 36)
        }
        .padding(11)
        .background(
            isSelected ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color(NSColor.selectedContentBackgroundColor) : Color(NSColor.separatorColor),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RightClickCatcher { selectedCommit = commit })
        .onTapGesture { selectedCommit = commit }
        .contextMenu {
            if commit.hasBackup {
                Button {
                    restore()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                draftMessage = commit.message
                showRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Restore Failed", isPresented: $showRestoreError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This version could not be restored. The backup or original file may be missing, or the file was never saved to disk.")
        }
        .alert("Rename Commit", isPresented: $showRename) {
            TextField("Commit message", text: $draftMessage)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                versionStore.rename(commit: commit, to: draftMessage)
                // Keep the open detail panel in sync if this commit is selected.
                if selectedCommit?.id == commit.id {
                    var updated = commit
                    updated.message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    selectedCommit = updated
                }
            }
        }
        .confirmationDialog("Delete this commit?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if selectedCommit?.id == commit.id { selectedCommit = nil }
                versionStore.delete(commit: commit)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its backup is removed too. This can't be undone.")
        }
        .task(id: commit.thumbnailPath) {
            guard let path = commit.thumbnailPath else { return }
            thumbnail = NSImage(contentsOfFile: path)
        }
    }
}

/// Transparent overlay that fires `onRightClick` on a right mouse press while
/// letting left clicks (and SwiftUI's own `.contextMenu`) pass through. Used so
/// right-clicking a commit row selects it — switching the canvas — before the
/// context menu's action is even chosen.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onRightClick) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void

        init(_ onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Only claim right-click events; return nil for everything else so left
        // clicks reach SwiftUI's tap gesture underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp: return self
            default: return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick()
            // Bubble up so SwiftUI's .contextMenu still pops up.
            super.rightMouseDown(with: event)
        }
    }
}

struct HeatmapSection: View {
    @EnvironmentObject var versionStore: VersionStore

    /// Anchor inside the currently displayed month. Defaults to today's month.
    @State private var monthAnchor: Date = Date()

    /// Day whose activity popover is currently shown (set on hover).
    @State private var hoveredDay: Date?

    private let calendar = Calendar.current

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM, yyyy"
        return f
    }()

    var body: some View {
        let data = buildHeatmapData()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(Self.monthFormatter.string(from: monthAnchor))
                    .font(.body)
                Spacer()
                HStack(alignment: .center) {
                    Button { shiftMonth(by: -1) } label: {
                        Image(systemName: "chevron.up")
                            .fontWeight(.bold)
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .imageScale(.small)
                    }
                    Button { shiftMonth(by: 1) } label: {
                        Image(systemName: "chevron.down")
                            .fontWeight(.bold)
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .imageScale(.small)
                    }
                }
                .buttonStyle(.plain)
            }
            VStack {
                HStack(spacing: 5) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }

                VStack(spacing: 5) {
                    ForEach(Array(monthWeeks().enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 5) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                cell(for: day, data: data)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// DEBUG: paint every day a random tier instead of the computed activity level.
    private static let debugRandomColors = false

    private func cell(for day: Date, data: HeatmapData) -> some View {
        let level = Self.debugRandomColors
            ? debugLevel(for: day)
            : data.level(forDay: day, calendar: calendar)
        let deltas = data.deltas(forDay: day, calendar: calendar)
        return RoundedRectangle(cornerRadius: 4)
            .fill(color(forLevel: level))
            .aspectRatio(1, contentMode: .fit)
            .onHover { inside in
                guard deltas != nil else { return }
                hoveredDay = inside ? calendar.startOfDay(for: day) : nil
            }
            .popover(isPresented: Binding(
                get: { hoveredDay == calendar.startOfDay(for: day) && deltas != nil },
                set: { if !$0 { hoveredDay = nil } }
            ), arrowEdge: .top) {
                if let deltas {
                    deltaPopover(deltas)
                }
            }
    }

    /// Per-app "icon  +N  -N" layer-change summary shown when hovering a day with
    /// activity. Each editing app (Ps / Ai) gets its own row.
    private func deltaPopover(_ deltas: [HeatmapData.AppDelta]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(deltas, id: \.app) { delta in
                HStack(spacing: 6) {
                    appIconView(for: delta.app)
                        .frame(width: 14, height: 14)
                    if delta.added > 0 {
                        Text("+\(delta.added)")
                            .foregroundColor(Color(NSColor.systemGreen))
                    }
                    if delta.removed > 0 {
                        Text("-\(delta.removed)")
                            .foregroundColor(Color(NSColor.systemRed))
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The editing app's real macOS application icon, falling back to the bundled
    /// brand glyph when the app isn't installed.
    @ViewBuilder
    private func appIconView(for app: PluginMessage.AppSource) -> some View {
        if let icon = Self.appIcon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(fallbackIconName(for: app))
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    /// Asset-catalog name of the bundled brand glyph for an editing app.
    private func fallbackIconName(for app: PluginMessage.AppSource) -> String {
        switch app {
        case .photoshop: return "Ps"
        case .illustrator: return "Ai"
        }
    }

    private static let appIconCache = NSCache<NSString, NSImage>()

    /// Looks up the installed app's icon by bundle identifier (cached).
    private static func appIcon(for app: PluginMessage.AppSource) -> NSImage? {
        let bundleID: String
        switch app {
        case .photoshop: bundleID = "com.adobe.Photoshop"
        case .illustrator: bundleID = "com.adobe.illustrator"
        }
        if let cached = appIconCache.object(forKey: bundleID as NSString) { return cached }
        // Beta and release builds share a bundle ID (e.g. com.adobe.Photoshop), so
        // prefer a non-"Beta" install; fall back to whatever LaunchServices returns.
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        guard let url = candidates.first(where: { !$0.path.localizedCaseInsensitiveContains("beta") })
            ?? candidates.first
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIconCache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    /// Deterministic 0…4 level seeded by the day, so colors stay stable across redraws.
    /// Uses splitmix64 mixing so consecutive days scatter instead of trending in order.
    private func debugLevel(for day: Date) -> Int {
        let dayNumber = Int64(day.timeIntervalSince1970 / 86400)
        var z = UInt64(bitPattern: dayNumber) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Int(z % 5)
    }

    /// green quaternary → primary as the level rises; level 0 is the empty gray.
    private func color(forLevel level: Int) -> Color {
        switch level {
        case 1: return Color(NSColor.systemGreen).opacity(0.25)
        case 2: return Color(NSColor.systemGreen).opacity(0.5)
        case 3: return Color(NSColor.systemGreen).opacity(0.75)
        case 4: return Color(NSColor.systemGreen)
        default: return Color(NSColor.quaternaryLabelColor)
        }
    }

    // MARK: - Month grid

    private func shiftMonth(by months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: monthAnchor) {
            monthAnchor = next
        }
    }

    /// Weekday-aligned month grid like a real calendar: rows start on Sunday
    /// (matching the S M T W T F S header), leading cells before the 1st show the
    /// previous month's trailing days, and trailing cells after the last day show
    /// the next month's leading days. Always 5 rows of 7 so the sidebar block never
    /// changes size — months spanning 6 weeks get their last day(s) clipped.
    private func monthWeeks() -> [[Date]] {
        guard let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthAnchor))
        else { return [] }

        // .weekday is 1 (Sunday) … 7 (Saturday); back up to the Sunday on/before the 1st.
        let leading = calendar.component(.weekday, from: firstOfMonth) - 1
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth)
        else { return [] }

        let days: [Date] = (0..<35).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
        return stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
    }

    // MARK: - Data

    private func buildHeatmapData() -> HeatmapData {
        HeatmapData.build(from: Array(versionStore.commitCache.values), calendar: calendar)
    }
}

struct DirectoryTreeSection: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live group: files currently open in Photoshop / Illustrator.
            // Renders nothing (no header, no gap) when no document is open.
            LiveGroupSection()
            ForEach(directoryStore.groups) { group in
                DirectoryGroupSection(
                    group: group,
                    initiallyExpanded: directoryStore.isGroupExpanded(group.id),
                    onRemove: { directoryStore.removeGroup(id: group.id) }
                )
            }
        }
    }
}

/// The "Now Editing" group pinned at the top of the sidebar. Lists the documents
/// currently open in the connected design apps and lets you select one — selecting
/// a saved file mirrors a normal directory selection so the canvas + commit list
/// update. Hidden entirely while nothing is open.
struct LiveGroupSection: View {
    @EnvironmentObject var liveStore: LiveDocumentStore

    var body: some View {
        if !liveStore.documents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    LivePulseDot()
                    Text("Now Editing")
                        .font(.body)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(liveStore.documents) { doc in
                        LiveDocumentRow(doc: doc)
                    }
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: liveStore.documents)
        }
    }
}

/// Small gray "live" indicator with a gentle pulse.
struct LivePulseDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color(NSColor.tertiaryLabelColor))
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

struct LiveDocumentRow: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    let doc: LiveDocument
    @State private var icon: NSImage? = nil

    private var isSelected: Bool {
        guard let url = doc.url else { return false }
        return directoryStore.selectedFile?.path == url.path
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
            Text(doc.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : Color(NSColor.labelColor))
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(doc.hasFile ? 1 : 0.55)
        .overlay(
            RowClickCatcher { _ in
                // Only saved documents have a file on disk to preview/select.
                if let url = doc.url { directoryStore.selectedFile = url }
            }
        )
        .help(doc.hasFile ? doc.path : "\(doc.name) — unsaved")
        .task(id: doc.id) {
            icon = await LiveDocumentRow.loadIcon(for: doc)
        }
    }

    /// File icon for saved docs (shows the .psd/.ai document icon); a generic app
    /// icon for unsaved ones, which have no file on disk to read an icon from.
    private static func loadIcon(for doc: LiveDocument) async -> NSImage {
        if let url = doc.url {
            let path = url.path
            return await Task.detached(priority: .userInitiated) {
                NSWorkspace.shared.icon(forFile: path)
            }.value
        }
        let bundleID = doc.app == .photoshop ? "com.adobe.Photoshop" : "com.adobe.illustrator"
        return await Task.detached(priority: .userInitiated) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
            return NSWorkspace.shared.icon(for: .data)
        }.value
    }
}

struct DirectoryGroupSection: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    let group: DirectoryGroup
    let onRemove: () -> Void
    @State private var children: [DirectoryItem] = []
    @State private var childrenLoaded: Bool = false
    @State private var isExpanded: Bool
    // Width of the group's content area, used as the min width of the horizontally
    // scrollable children so short names still fill the column.
    @State private var contentWidth: CGFloat = 0
    @State private var canFadeLeading: Bool = false
    @State private var canFadeTrailing: Bool = false

    init(group: DirectoryGroup, initiallyExpanded: Bool, onRemove: @escaping () -> Void) {
        self.group = group
        self.onRemove = onRemove
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 見出し（名前＋シェブロン）は横スクロールに含めず、シェブロンを右端に固定する
            HStack {
                Text(group.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Spacer()
                Image(systemName: "chevron.down")
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                directoryStore.setGroupExpanded(group.id, isExpanded)
            }
            .contextMenu {
                Button("Remove Group", role: .destructive) { onRemove() }
            }

            if isExpanded {
                Group {
                    if childrenLoaded && children.isEmpty {
                        Text("Empty")
                            .font(.callout)
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                            .padding(.leading, 4)
                    } else {
                        // 横スクロール: 中身（行）だけを対象にし、省略された名前を全部読めるようにする
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(children) { item in
                                    DirectoryRow(
                                        item: item,
                                        depth: 0,
                                        initiallyExpanded: directoryStore.isPathExpanded(item.path)
                                    )
                                }
                            }
                            .frame(minWidth: contentWidth, alignment: .leading)
                        }
                        .onScrollGeometryChange(for: Bool.self) { geo in
                            geo.contentOffset.x > 0.5
                        } action: { _, newValue in
                            withAnimation(.easeInOut(duration: 0.2)) { canFadeLeading = newValue }
                        }
                        .onScrollGeometryChange(for: Bool.self) { geo in
                            geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - 0.5
                        } action: { _, newValue in
                            withAnimation(.easeInOut(duration: 0.2)) { canFadeTrailing = newValue }
                        }
                        .mask(
                            HStack(spacing: 0) {
                                LinearGradient(
                                    colors: canFadeLeading ? [.clear, .black] : [.black, .black],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: 20)
                                Color.black
                                LinearGradient(
                                    colors: canFadeTrailing ? [.black, .clear] : [.black, .black],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: 20)
                            }
                        )
                    }
                }
                .task(id: group.path) {
                    let url = group.url
                    children = await Task.detached(priority: .userInitiated) {
                        loadDirectoryItems(at: url)
                    }.value
                    childrenLoaded = true
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { contentWidth = $0 }
    }
}

/// Handles row clicks via AppKit so a single click fires *immediately* instead of
/// waiting out the system double-click interval (~0.5s) the way two stacked
/// SwiftUI `onTapGesture`s do. Reports the click count so the caller can decide.
private struct RowClickCatcher: NSViewRepresentable {
    var onClick: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RowClickNSView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RowClickNSView)?.onClick = onClick
    }
}

private final class RowClickNSView: NSView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }
}

struct DirectoryRow: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    let item: DirectoryItem
    let depth: Int
    @State private var children: [DirectoryItem] = []
    @State private var icon: NSImage? = nil
    // Local expansion state: toggling it animates only this row's subtree instead
    // of republishing through the store and re-rendering the whole tree.
    @State private var isExpanded: Bool

    init(item: DirectoryItem, depth: Int, initiallyExpanded: Bool) {
        self.item = item
        self.depth = depth
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    // Chevron, file icon, and each indent cell all share this width so the
    // whole tree stays on one column grid.
    private let iconUnit: CGFloat = 16
    private let rowSpacing: CGFloat = 4
    private var isSelected: Bool { directoryStore.selectedFile?.path == item.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: rowSpacing) {
                // One transparent cell per depth level — same width as the
                // chevron/icon columns, so it shares the row's spacing and the
                // tree stays on one grid.
                ForEach(0..<depth, id: \.self) { _ in
                    Color.clear.frame(width: iconUnit, height: iconUnit)
                }
                Image(systemName: "chevron.right")
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .opacity(item.isDirectory ? 1 : 0)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: iconUnit, height: iconUnit)
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: iconUnit, height: iconUnit)
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(NSColor.labelColor))
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                RowClickCatcher { clickCount in
                    if item.isDirectory {
                        // Folders have no double-click action: every click toggles,
                        // regardless of click count, so rapid open/close stays responsive.
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                        directoryStore.setPathExpanded(item.path, isExpanded)
                    } else if item.isPreviewable {
                        if clickCount >= 2 {
                            NSWorkspace.shared.open(item.url)
                        } else {
                            directoryStore.selectedFile = item.url
                        }
                    }
                }
            )

            // Children are loaded lazily — only while expanded, exactly one level
            // deep. This avoids the grandchild read-storm on every expand.
            if isExpanded && item.isDirectory {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(children) { child in
                        DirectoryRow(
                            item: child,
                            depth: depth + 1,
                            initiallyExpanded: directoryStore.isPathExpanded(child.path)
                        )
                    }
                }
                .padding(.top, children.isEmpty ? 0 : 8)
                .task(id: item.path) {
                    let url = item.url
                    children = await Task.detached(priority: .userInitiated) {
                        loadDirectoryItems(at: url)
                    }.value
                }
            }
        }
        .task(id: item.path) {
            icon = await IconCache.shared.icon(for: item)
        }
    }
}

#Preview {
    ContentView()
}
