import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case single = "Single"
    case compare = "Compare"
    case slider = "Slider"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @State private var isInspectorPresented: Bool = true
    @State private var selectedMode: ViewMode = .single
    @State private var canvasScale: CGFloat = 1.0
    @State private var selectedCommit: Commit? = nil

    var body: some View {
        NavigationSplitView {
            LeftSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 230)
        } detail: {
            CanvasView(scale: $canvasScale, selectedCommit: selectedCommit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .inspector(isPresented: $isInspectorPresented) {
                    RightSidebar(selectedCommit: $selectedCommit)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 400)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isInspectorPresented.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onChange(of: directoryStore.selectedFile) { _ in
            selectedCommit = nil
        }
    }
}

struct CanvasView: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore
    @Binding var scale: CGFloat
    let selectedCommit: Commit?
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize = .zero
    @State private var displayImage: NSImage? = nil

    private var taskID: String {
        if let id = selectedCommit?.id { return "commit:\(id)" }
        if let path = directoryStore.selectedFile?.path { return "file:\(path)" }
        return "none"
    }

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .overlay {
                    ZStack {
                        if let img = displayImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .padding(20)
                                .scaleEffect(scale * gestureScale)
                                .offset(
                                    x: offset.width + gestureOffset.width,
                                    y: offset.height + gestureOffset.height
                                )
                        }

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
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
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

struct CommitDayGroup: Identifiable {
    let id: String        // "yyyy-MM-dd"
    let label: String     // "Commits on June 1, 2026"
    let commits: [Commit] // newest first
    var isExpanded: Bool = false
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .long
    f.timeStyle = .none
    return f
}()

private let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
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
        var seen: [String: [Commit]] = [:]
        for commit in commits {
            let key = dayKeyFormatter.string(from: commit.timestamp)
            seen[key, default: []].append(commit)
        }
        return seen
            .map { key, group in
                CommitDayGroup(
                    id: key,
                    label: "Commits on \(dayFormatter.string(from: group[0].timestamp))",
                    commits: group.sorted { $0.timestamp > $1.timestamp }
                )
            }
            .sorted { $0.id > $1.id }
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
private enum CommitListItem: Identifiable {
    case single(Commit)
    case autosaveGroup(id: String, commits: [Commit])

    var id: String {
        switch self {
        case .single(let c): return c.id
        case .autosaveGroup(let gid, _): return "g-\(gid)"
        }
    }
}

private func chunkCommits(_ commits: [Commit]) -> [CommitListItem] {
    var result: [CommitListItem] = []
    var buffer: [Commit] = []
    for commit in commits {
        if commit.isAutosave {
            buffer.append(commit)
        } else {
            if !buffer.isEmpty {
                result.append(.autosaveGroup(id: buffer[0].id, commits: buffer))
                buffer = []
            }
            result.append(.single(commit))
        }
    }
    if !buffer.isEmpty {
        result.append(.autosaveGroup(id: buffer[0].id, commits: buffer))
    }
    return result
}

struct CommitDaySection: View {
    let group: CommitDayGroup
    @Binding var selectedCommit: Commit?
    let autoSaveNumbers: [String: Int]
    @State private var expandedGroups: Set<String> = []

    private var chunked: [CommitListItem] { chunkCommits(group.commits) }

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
                                isSelected: selectedCommit?.id == commit.id
                            ) { selectedCommit = commit }
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
                                isSelected: selectedCommit?.id == commit.id,
                                autoSaveIndex: autoSaveNumbers[commit.id]
                            ) { selectedCommit = commit }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

struct CommitItemView: View {
    let commit: Commit
    let isSelected: Bool
    var autoSaveIndex: Int? = nil
    let onSelect: () -> Void
    @State private var thumbnail: NSImage? = nil

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
                    if let diff = commit.layerDiff, !diff.isEmpty {
                        HStack(spacing: 6) {
                            if diff.added.count > 0 {
                                Text("+\(diff.added.count)")
                                    .foregroundColor(Color(NSColor.systemGreen))
                            }
                            if diff.removed.count > 0 {
                                Text("-\(diff.removed.count)")
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
        .onTapGesture { onSelect() }
        .task(id: commit.thumbnailPath) {
            guard let path = commit.thumbnailPath else { return }
            thumbnail = NSImage(contentsOfFile: path)
        }
    }
}

struct HeatmapSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("May, 2026")
                    .font(.body)
                Spacer()
                HStack(alignment:.center) {
                    Image(systemName: "chevron.up")
                        .fontWeight(.bold)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .imageScale(.small)
                    Image(systemName: "chevron.down")
                        .fontWeight(.bold)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .imageScale(.small)
                }
            }
            VStack() {
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
                    ForEach(0..<5) { _ in
                        HStack(spacing: 5) {
                            ForEach(0..<7) { _ in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(NSColor.quaternaryLabelColor))
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DirectoryTreeSection: View {
    @EnvironmentObject var directoryStore: DirectoryGroupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

private nonisolated let previewableExtensions: Set<String> = [
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
private nonisolated func loadDirectoryItems(at url: URL) -> [DirectoryItem] {
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
private nonisolated func directoryHasVisibleContent(_ url: URL) -> Bool {
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

    private let indentUnit: CGFloat = 16
    private var isSelected: Bool { directoryStore.selectedFile?.path == item.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * indentUnit)
                }
                Image(systemName: "chevron.right")
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .opacity(item.isDirectory ? 1 : 0)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 16)
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
