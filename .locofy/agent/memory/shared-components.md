# Shared Component Catalog

> Last updated: Run 1 (generated-OMGnhF)

| Shared component | Status | Used by screens | Public API | File |
|------------------|--------|-----------------|------------|------|
| CommitCardView | new | DesignHub | `time: String, title: String, thumbnailName: String` | UIComponents/CommitCardView.swift |

## Notes

- Only one incoming screen (`DesignHub`) in this run — no cross-screen primitives.
- `CommitCardView`: the bordered card pattern (`VStack` with time label + bold title + thumbnail `Image` + `overlay(RoundedRectangle)`) repeats ≥5 times within `DesignHub.swift` (Auto-save 6, Auto-save 5, Auto-save 4, Adjust title position, First commit, Current version — second date group). Extracted as shared component.
- The two `TextField` occurrences (lines 985, 1288) represent the "Current version" display-card. These visually display static commit title text and will be replaced with the `CommitCardView` component.
- No `AppHeaderBar`, `PrimaryCTAButton`, `FormTextField`, `SearchField`, or `SegmentedPillPicker` patterns found — this is a macOS desktop design hub with no matching mobile primitives.
