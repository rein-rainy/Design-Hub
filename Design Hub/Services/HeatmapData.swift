import Foundation

/// Per-day activity scores + relative (quartile) level thresholds for the
/// calendar heatmap. All the aggregation math lives here so the view only maps
/// a level (0…4) to a colour.
struct HeatmapData {
    /// startOfDay → total layer changes that day (only days with score > 0 are present).
    let scores: [Date: Int]
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

    /// Builds daily scores from every project's commits, then derives quartile
    /// thresholds over the nonzero days.
    static func build(from commitsByProject: [[Commit]], calendar: Calendar) -> HeatmapData {
        var scores: [Date: Int] = [:]
        for commits in commitsByProject {
            for commit in commits {
                let amount = changeAmount(commit)
                guard amount > 0 else { continue }
                let day = calendar.startOfDay(for: commit.timestamp)
                scores[day, default: 0] += amount
            }
        }
        let sorted = scores.values.sorted()
        return HeatmapData(scores: scores,
                           q1: percentile(sorted, 0.25),
                           q2: percentile(sorted, 0.50),
                           q3: percentile(sorted, 0.75))
    }

    /// Layer changes a commit represents. The oldest commit of a project has no previous
    /// snapshot to diff against (layerDiff == nil), so we count its whole tree as additions
    /// — file creation is real work.
    private static func changeAmount(_ commit: Commit) -> Int {
        if let diff = commit.layerDiff {
            return diff.added.count + diff.removed.count
        }
        return commit.layerCount
    }

    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }
}
