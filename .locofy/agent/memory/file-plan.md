# File Plan

> Run 1 (generated-OMGnhF)

| File | Action | Est. Lines | Extracted Components | Notes |
|------|--------|-----------|---------------------|-------|
| Design Hub/Features/DesignHub/Views/DesignHubView.swift | create | ~340 | CommitCardView (calls UIComponents) | Enhanced version of Components/DesignHub.swift; moved to Features layout; struct renamed to DesignHubView |
| Design Hub/UIComponents/CommitCardView.swift | create | ~45 | — | Shared commit card: time + title + thumbnail, bordered card shape |
| Design Hub/DesignSystem/DesignTokens.swift | modify | ~110 | — | Move from root; semantic token renames for auto-numeric tokens; keep Figma variable tokens verbatim |
| Design Hub/DesignSystem/AppFonts.swift | create | ~20 | — | SF Pro font constant; relativeTo: body |
| Design Hub/DesignSystem/IconNames.swift | create | ~35 | — | All image asset names referenced in DesignHub |
| Design Hub/DesignSystem/ColorNames.swift | create | ~15 | — | Color name constants mapping to Colors.xcassets |
| Design Hub/DesignSystem/AccessibilityCommon.swift | create | ~65 | — | Full AccessibilityCommon ViewModifier per policy |
| Design Hub/Colors.xcassets/Contents.json | create | ~3 | — | Root manifest for Colors xcassets |
| Design Hub/Colors.xcassets/[colorName].colorset/Contents.json | create | ~8 each × ~12 | — | One per color from DesignTokens color section |
| Design Hub/Localization.swift | create | ~40 | — | enum Localization: String + .localized accessor |
| Design Hub/Localizable.xcstrings | create | ~60 | — | All localization key→value pairs |
| Design Hub/AppConstants.swift | create | ~20 | — | Non-token literals (commit count "14 Commits", date labels, etc.) |
| Design Hub/AccessibilityIdentifiers.swift | create | ~25 | — | All accessibility identifiers used in DesignHubView |
| Design Hub/Components/DesignHub.swift | delete/replace | — | — | Raw merged file replaced by Features layout; file no longer needed |

## Migration Notes

- Project uses `PBXFileSystemSynchronizedRootGroup` — files placed in `Design Hub/` folder are auto-included.
- No `RootTabView` needed — macOS flat 3-panel layout, no tab bar.
- `ContentView.swift` is pre-existing and out of scope — do NOT modify.
- `DesignTokens.swift` moves from `Design Hub/DesignTokens.swift` to `Design Hub/DesignSystem/DesignTokens.swift`.
- Color token values stay in `DesignTokens.swift` for Figma-variable ones; all `Color(red:...)` migrations go to `Colors.xcassets` + `ColorNames`.
