import Foundation

/// Per-day activity scores + relative (quartile) level thresholds for the
/// calendar heatmap. All the aggregation math lives here so the view only maps
/// a level (0…4) to a colour.
struct HeatmapData {
    /// Layers added / removed on a single day, attributed to one editing app.
    struct AppDelta: Equatable {
        let app: PluginMessage.AppSource
        let added: Int
        let removed: Int
    }

    /// startOfDay → total layer changes that day (only days with score > 0 are present).
    let scores: [Date: Int]
    /// startOfDay → per-app added/removed breakdown (only days with activity are present).
    let deltasByDay: [Date: [AppDelta]]
    /// Quartile cut points over all nonzero daily scores (25th / 50th / 75th percentile).
    let q1: Int
    let q2: Int
    let q3: Int

    /// 0 = no activity (gray); 1…4 = increasing green tiers.
    func level(forDay day: Date, calendar: Calendar) -> Int {
        let s = scores[calendar.startOfDay(for: day)] ?? 0
        guard s > 0 else { return 0 }
        if s <= q1 { return 1 }
        if s <= q2 { return 2 }
        if s <= q3 { return 3 }
        return 4
    }

    /// Per-app added/removed breakdown for a given day, or nil when there was no
    /// activity. Photoshop is listed before Illustrator so the popover row order is
    /// stable.
    func deltas(forDay day: Date, calendar: Calendar) -> [AppDelta]? {
        let key = calendar.startOfDay(for: day)
        guard let deltas = deltasByDay[key], !deltas.isEmpty else { return nil }
        return deltas
    }

    /// Builds daily scores from every project's commits, then derives quartile
    /// thresholds over the nonzero days.
    ///
    /// Only the user's own (manual) commits count: auto-saves are transient
    /// history, not deliberate work. Each commit's pre-computed change is vs its
    /// immediate predecessor — which may be an auto-save that would absorb part
    /// of the change — so diffs are recomputed here between consecutive manual
    /// commits instead.
    static func build(from commitsByProject: [[Commit]], calendar: Calendar) -> HeatmapData {
        var scores: [Date: Int] = [:]
        // day → app → accumulated (added, removed)
        var perApp: [Date: [PluginMessage.AppSource: (added: Int, removed: Int)]] = [:]
        for commits in commitsByProject {
            let manual = commits.filter { !$0.isAutosave }   // newest first
            for (i, commit) in manual.enumerated() {
                let previous = i + 1 < manual.count ? manual[i + 1] : nil
                let change = changeCounts(commit, previous: previous)
                let amount = change.added + change.removed
                guard amount > 0 else { continue }
                let day = calendar.startOfDay(for: commit.timestamp)
                let app: PluginMessage.AppSource = commit.shapeCount != nil ? .illustrator : .photoshop
                scores[day, default: 0] += amount
                var byApp = perApp[day] ?? [:]
                let prev = byApp[app] ?? (0, 0)
                byApp[app] = (prev.added + change.added, prev.removed + change.removed)
                perApp[day] = byApp
            }
        }
        // Fixed app order so multi-app days render Ps above Ai consistently.
        let order: [PluginMessage.AppSource] = [.photoshop, .illustrator]
        let deltasByDay = perApp.mapValues { byApp -> [AppDelta] in
            order.compactMap { app in
                guard let c = byApp[app] else { return nil }
                return AppDelta(app: app, added: c.added, removed: c.removed)
            }
        }
        let sorted = scores.values.sorted()
        return HeatmapData(scores: scores,
                           deltasByDay: deltasByDay,
                           q1: percentile(sorted, 0.25),
                           q2: percentile(sorted, 0.50),
                           q3: percentile(sorted, 0.75))
    }

    /// Activity a commit represents vs the previous *manual* commit. The oldest
    /// manual commit of a project has no previous snapshot to diff against, so
    /// its whole document counts as additions — file creation is real work.
    ///
    /// Illustrator commits carry shape data and are diffed by shape identity
    /// (or net count); Photoshop commits fall back to layer-tree diffing.
    private static func changeCounts(_ commit: Commit, previous: Commit?) -> (added: Int, removed: Int) {
        guard let previous else {
            return (added: commit.shapeCount ?? commit.layerCount, removed: 0)
        }
        if let change = ShapeChange.between(oldIds: previous.shapeIds, oldCount: previous.shapeCount,
                                            newIds: commit.shapeIds, newCount: commit.shapeCount) {
            return (added: change.added, removed: change.removed)
        }
        let diff = LayerDiffer.diff(from: previous.layerTree, to: commit.layerTree)
        return (added: diff.added.count, removed: diff.removed.count)
    }

    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }
}
