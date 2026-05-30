# Decisions Audit

> Run 1 (generated-OMGnhF)

| Catalog row | Trigger fired | Question asked? (tool call id) | User's answer | Action this run |
|-------------|---------------|---------------------------------|---------------|------------------|
| CommitCardView | new — used by only 1 feature (DesignHub), no cross-feature promotion trigger | n/a — trigger did not fire | n/a | Create `UIComponents/CommitCardView.swift`; replace 5+ inline instances |

## Notes

- No promotion trigger: `CommitCardView` is used only by the single incoming screen `DesignHub`. No `⚠️ promotion-candidate` flag and no cross-feature usage.
- No slot-refactor trigger: `CommitCardView` has a simple, fixed 3-prop API (`time`, `title`, `thumbnailName`). No stringly-typed growth or widget-kind variation.
- No fork-vs-generalize trigger: only one card shape across all usages — same visual, same widget kinds.
