# Design Hub — Project Analysis

## Project Overview
- **Type:** macOS SwiftUI app
- **Xcode project:** `Dev/Design Hub/Design Hub.xcodeproj`
- **Bundle/Target:** `Design Hub`
- **Entry point:** `Design Hub/Design_HubApp.swift` → `Design_HubApp` (@main)
- **Root view:** `ContentView` in `Design Hub/ContentView.swift`
- **Platform:** macOS (hiddenTitleBar window style, fixed 1284×760 window)
- **Swift version:** Swift 5+ (Xcode 16+, objectVersion 77)

## Project Structure

```
Dev/Design Hub/
├── Design Hub.xcodeproj/      # Xcode project (PBXFileSystemSynchronizedRootGroup)
└── Design Hub/
    ├── Design_HubApp.swift    # @main App entry
    ├── ContentView.swift      # All screens + data models (single file)
    └── Assets.xcassets/
        ├── AccentColor.colorset/
        ├── AppIcon.appiconset/
        ├── CommitThumbA.imageset/  (thumb_a.png)
        ├── CommitThumbB.imageset/  (thumb_b.png)
        ├── DonutPoster.imageset/   (donut_poster.png)
        └── PreviewMain.imageset/   (preview_main.png)
```

## Screens

| Screen/View | File | Description |
|-------------|------|-------------|
| `ContentView` | `ContentView.swift` | Root 3-panel layout (LeftSidebar + CenterPanel + RightPanel) |
| `LeftSidebar` | `ContentView.swift` | Traffic lights, mini calendar, file tree |
| `MiniCalendar` | `ContentView.swift` | May 2026 activity heatmap calendar |
| `TreeItemView` | `ContentView.swift` | Recursive file tree row with expand/select |
| `CenterPanel` | `ContentView.swift` | Breadcrumb + preview image + toolbar |
| `RightPanel` | `ContentView.swift` | Commits list with autosave accordion |
| `CommitCard` | `ContentView.swift` | Single commit item card |
| `TrafficLights` | `ContentView.swift` | macOS window control buttons (red/yellow/green) |

## Data Models (in ContentView.swift)
- `enum ActivityLevel` — `.none, .low, .medium, .high, .full`
- `struct TreeNode` — file tree node (id, name, isFile, children)
- `struct CommitItem` — commit history entry (id, time, title, imageName, isCurrent)
- `func activityColor(_:)` — maps ActivityLevel → Color

## SVG Shapes (in ContentView.swift)
- `CaretRightShape`, `CaretDownShape` — tree expand/collapse
- `FolderShape` — file icon
- `RectIconShape`, `SplitIconShape`, `DiffIconShape` — toolbar view-mode icons

## Design Tokens / Color System
- **No separate DesignTokens file** — colors defined as `Color` extensions in `ContentView.swift`
- `Color.borderColor`, `Color.textPrimary`, `Color.textSecondary`, `Color.selectedBg`
- Activity colors defined inline via `activityColor()` function
- Fonts: `SF Pro` custom font, sizes 9/11/12/13/17

## Navigation Structure
- **No TabView, NavigationStack, or NavigationView** — flat 3-panel desktop layout
- Navigation via file tree selection (sidebar) + breadcrumb (center)
- State: `@State var expanded: Set<String>` + `@State var selected: String`

## Assets
- `CommitThumbA` — commit card thumbnail A
- `CommitThumbB` — commit card thumbnail B
- `DonutPoster` — not referenced in ContentView (available for use)
- `PreviewMain` — donut poster image shown in CenterPanel

## Shared Components Inventory
_(No dedicated shared-component directories — all views are in ContentView.swift as a single monolithic file)_

| Name | File | Public API | Shape |
|------|------|------------|-------|
| TrafficLights | ContentView.swift (inline) | none | HStack of 3 colored circles with border |
| MiniCalendar | ContentView.swift (inline) | none | VStack: month header + day labels + activity grid |
| TreeItemView | ContentView.swift (inline) | node: TreeNode, level: Int, expanded: Binding, selected: Binding, isLast: Bool, parentHasBelow: [Bool] | Recursive tree row with connector lines |
| CommitCard | ContentView.swift (inline) | item: CommitItem | HStack: text block + thumbnail image, white bg, rounded border |
| LeftSidebar | ContentView.swift (inline) | expanded: Binding, selected: Binding | 170pt sidebar: traffic lights + calendar + tree |
| CenterPanel | ContentView.swift (inline) | none | Preview canvas with breadcrumb + toolbar |
| RightPanel | ContentView.swift (inline) | none | 300pt commit history panel |

## Missing Dependencies
- No external Swift packages or third-party frameworks required
- No Package.swift
- No CocoaPods

## Notes
- Project uses Xcode's `PBXFileSystemSynchronizedRootGroup` — new files added to the `Design Hub/` folder are automatically included in the build without modifying the `.xcodeproj`
- Incoming Locofy code merged in run 1: `DesignHub.swift` + `DesignTokens.swift` from generated-OMGnhF
- `DesignTokens.swift` added at `Design Hub/DesignTokens.swift` — provides centralized design tokens for all future screens
- `DesignHub.swift` added at `Design Hub/Components/DesignHub.swift` — Locofy-generated flat-copy of the design screen

## Merge History
| Run | Date | Incoming | Files Added |
|-----|------|----------|-------------|
| 1 | 2025 | generated-OMGnhF | `DesignTokens.swift`, `Components/DesignHub.swift`, 20 new imagesets |
