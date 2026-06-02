import Foundation

/// A day's worth of commits, used to render the date-sectioned commit history.
struct CommitDayGroup: Identifiable {
    let id: String        // "yyyy-MM-dd"
    let label: String     // "Commits on June 1, 2026"
    let commits: [Commit] // newest first
    var isExpanded: Bool = false
}

/// One row in the commit list: either a standalone (manual) commit, or a run of
/// consecutive auto-saves collapsed into a single expandable group.
enum CommitListItem: Identifiable {
    case single(Commit)
    case autosaveGroup(id: String, commits: [Commit])

    var id: String {
        switch self {
        case .single(let c): return c.id
        case .autosaveGroup(let gid, _): return "g-\(gid)"
        }
    }
}

/// Pure grouping logic behind the commit history list. Keeps the date math and
/// autosave-run collapsing out of the views.
enum CommitGrouping {

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Buckets commits by calendar day, newest day and newest commit first.
    static func byDay(_ commits: [Commit]) -> [CommitDayGroup] {
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

    /// Collapses consecutive auto-save commits into `autosaveGroup` items while
    /// leaving manual commits as standalone `single` items. Order is preserved.
    static func chunkByAutosave(_ commits: [Commit]) -> [CommitListItem] {
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
}
