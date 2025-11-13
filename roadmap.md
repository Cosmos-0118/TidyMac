# MacCleaner UI & Logic Roadmap

## Milestone A — Dark Theme & Design System

- [x] Step 1 - Inventory current palettes and typography in `MacCleaner/Views/**/*.swift`, flag hard-coded colors (e.g. `.blue`, `.orange`) that violate the black/green/red/gray theme.
- [x] Step 2 - Define color tokens in an `Assets.xcassets/Theme.colorset` (black background, green success, red warning, gray surfaces) and expose via `Color("ThemeBackground")`, etc., for SwiftUI previews.
- [x] Step 3 - Create a shared `DesignSystem.swift` under `MacCleaner/Views/Common/` with typography, spacing, and button styles aligned to the theme, replacing `CustomButtonStyle` duplicates.
- [x] Step 4 - Update `ContentView/ContentView.swift` to apply a global `preferredColorScheme(.dark)` and inject the shared palette using environment values.

## Milestone B — Reusable Components & Layout Polish

- [x] Step 5 - Replace ad-hoc `VStack` layouts with `Grid`/`NavigationSplitView` in `Dashboard.swift` to support responsive sidebar navigation on macOS.
- [x] Step 6 - Implement reusable status cards (`StatusCard`, `MetricGauge`) in `Views/Common/Components/` for dashboard metrics, with accent colors pulled from the theme tokens.
- [x] Step 7 - Add accessibility variants (VoiceOver labels, dynamic type) across `Dashboard`, `SystemCleanup`, `LargeFilesFinder`, and `Uninstaller` to ensure contrast and sizing compliance.
- [x] Step 8 - Introduce preview fixtures in `Preview Content/Preview Assets.xcassets` to visualize dark-theme states, loading, error, and success flows for each feature view.

## Milestone C — Feature Workflow Improvements

- [x] Step 9 - Redesign `SystemCleanup` sheet into a multi-step modal with progress, dry-run toggle, and failure recovery messaging using the new component library.
- [x] Step 10 - Expand `LargeFilesFinder.swift` to show sortable tables with file metadata (`FileDetail`) and inline exclusion switches, leveraging `Table` and theme-consistent row styling.
- [x] Step 11 - Refresh `Uninstaller.swift` with searchable app list, grouped by install location, and explicit red warning banners when root privileges are required.
- [x] Step 12 - Modernize `DeveloperTools.swift` to surface Xcode cache, simulators, and toolchains in separate tabs, using green accents for safe deletions and red for destructive actions.

## Milestone D — Architecture & Logic Refactors

- [x] Step 13 - Extract cleanup routines from `SystemCleanup` view into protocol-driven services (`CleanupService`, `LargeFileScanner`, `XcodeCacheCleaner`) under a new `MacCleaner/Services/` directory.
- [x] Step 14 - Refactor `SystemMonitorHelper` into an async `SystemMonitorService` that streams metrics via `AsyncStream` to view models in `DashboardViewModel.swift`.
- [x] Step 15 - Add feature-specific view models (`DashboardViewModel`, `SystemCleanupViewModel`, etc.) in `MacCleaner/ViewModels/` using `@Observable`/`ObservableObject` for state and dependency injection.
- [x] Step 16 - Implement privilege escalation wrapper using Authorization Services (`SMJobBless`) with confirmation prompts before calling destructive methods within the services layer.
- [x] Step 17 - Guard file deletions with exclusion lists and dry-run previews stored via `Codable` in `Application Support`, ensuring root paths like `/` are never touched without user-selected scope.

## Milestone E — Quality, Telemetry

- [x] Step 18 - Instrument services with `os.Logger` categories (`dashboard`, `cleanup`, `uninstaller`) and surface errors in a diagnostics panel accessible from `ContentView`.
- [x] Step 19 - Write unit tests in `MacCleanerTests/` for the new services covering large file detection, cleanup exclusions, and failure handling, plus XCUITests for the redesigned flows.
