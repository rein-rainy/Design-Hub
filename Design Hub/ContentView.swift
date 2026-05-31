import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case single = "Single"
    case compare = "Compare"
    case slider = "Slider"

    var id: String { rawValue }
}

struct ContentView: View {
    @State private var isInspectorPresented: Bool = true
    @State private var selectedMode: ViewMode = .single
    @State private var canvasScale: CGFloat = 1.0

    var body: some View {
        NavigationSplitView {
            LeftSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 230)
        } detail: {
            CanvasView(scale: $canvasScale)
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
                    RightSidebar()
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
    }
}

struct CanvasView: View {
    @Binding var scale: CGFloat
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize = .zero

    var body: some View {
        Color.clear
            .overlay {
                Image("KUA donuts")
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .scaleEffect(scale * gestureScale)
                    .offset(
                        x: offset.width + gestureOffset.width,
                        y: offset.height + gestureOffset.height
                    )
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeatmapSection()
            DirectoryTreeSection()
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    @State private var canFadeTop: Bool = false
    @State private var canFadeBottom: Bool = false
    private var project: Project? { versionStore.projects.first }

    private var commits: [Commit] {
        guard let p = project else { return [] }
        return versionStore.commits(forProjectID: p.id)
    }

    private var dayGroups: [CommitDayGroup] {
        let calendar = Calendar.current
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

            if commits.isEmpty {
                VStack(spacing: 6) {
                    Text("No commits yet")
                        .font(.body)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    Text("Save a file in Photoshop or Illustrator")
                        .font(.callout)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dayGroups) { group in
                            CommitDaySection(group: group)
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

struct CommitDaySection: View {
    let group: CommitDayGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(group.commits) { commit in
                        CommitItemView(commit: commit)
                    }
                }
            }
        }
    }
}

struct CommitItemView: View {
    let commit: Commit
    @State private var thumbnail: NSImage? = nil

    private var timeLabel: String {
        relativeFormatter.localizedString(for: commit.timestamp, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(timeLabel)
                    .font(.callout)
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                HStack(spacing: 6) {
                    Text("\(commit.layerCount) layers")
                        .font(.body)
                    if let diff = commit.layerDiff, !diff.isEmpty {
                        Text("+\(diff.added.count)")
                            .foregroundColor(Color(NSColor.systemGreen))
                        Text("-\(diff.removed.count)")
                            .foregroundColor(Color(NSColor.systemRed))
                    }
                }
                .font(.callout.monospacedDigit())
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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 1))
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
                    ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
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
    var body: some View {
        VStack(alignment: .leading) {
            DirectoryRow(name: "Project A", depth: 0)
            DirectoryRow(name: "Sub Folder", depth: 1)
            DirectoryRow(name: "Nested", depth: 2)
            DirectoryRow(name: "Project B", depth: 0)
            DirectoryRow(name: "Project C", depth: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DirectoryRow: View {
    let name: String
    let depth: Int

    private let indentUnit: CGFloat = 20

    var body: some View {
        HStack(alignment: .center) {
            Image(systemName: "chevron.right")
                .fontWeight(.semibold)
                .imageScale(.small)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name)
                .font(.callout)
        }
        .padding(.leading, CGFloat(depth) * indentUnit)
    }
}

#Preview {
    ContentView()
}
