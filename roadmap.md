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

## Cleanup Intelligence Roadmap

### Phase 0 — Baseline Safety & Telemetry

- Add unified diagnostics in `CleanupProgress` and `Diagnostics` to capture per-item reasons, guard decisions, and SIP denials (persist a rolling JSONL under `~/Library/Application Support/TidyMac/Diagnostics`).
- Wire `DeletionGuard` to expose live decisions (`allow | excluded | restricted | sip`) so UI can surface “why” before execution.
- Replace direct `removeItem` calls with `FileManager.trashItem` when running as the logged-in user to align with macOS safety expectations.

### Phase 1 — Candidate Inventory & Metadata Graph

- Create a shared `CleanupInventoryService` that wraps all scanners and returns `CleanupCandidate` records containing path, size, `URLResourceValues`, launch services bundle ID, code signature hash, and recent-process info.
- Expand scanners to cover browser caches (Safari WebKit, Chrome, Edge), orphaned `~/Library/Application Support` bundles, `~/Library/Preferences/*.plist` without matching executables, and `/Users/Shared` installers while honoring sandbox boundaries.
- Integrate `NSWorkspace.shared.runningApplications`, `pkgutil --pkg-info-plist`, and Spotlight metadata (`MDItemCopyAttribute`) to determine whether candidate owners are still installed or recently used.

### Phase 2 — Heuristic Scoring & Policy Engine

- Implement a scoring engine (`CleanupConfidence`) that maps the heuristics above into weighted signals, persisting the breakdown (`ageScore`, `appExistScore`, etc.) alongside each candidate.
- Layer risk tiers (Auto/Review/Observe) into view models so UI can default-select only high-confidence candidates while surfacing rationale strings.
- Build deduplication support by hashing large files (BLAKE3) and correlating duplicates across volumes, preferring newest/primary copies.

### Phase 3 — Quarantine-first Workflow

- Introduce a `QuarantineStore` that moves selected items into `~/Library/Application Support/TidyMac/Quarantine/<timestamp>/` with manifest, checksums, and original ACLs (`FileManager.copyItem` + `setAttributes`).
- Schedule background pruning of quarantine after 30 days, with manual restore (`QuarantineRestorer`) that validates checksums before replacing originals.
- Promote a multi-stage execution: 1) prepare candidate manifests, 2) perform user-space trash/quarantine, 3) request privileged helper only for paths flagged `requiresPrivilege`.

### Phase 4 — Privileged & SIP-aware Operations

- Replace ad-hoc `PrivilegedDeletionService` calls with an `SMAppService`/`SMJobBless` helper that can pre-flight SIP-protected paths, log entitlement failures, and surface precise remediation advice.
- Teach scanners to classify SIP-blocked items up front using `statfs`/`csr_check` (where available) so we never promise actions the helper cannot fulfil.
- Add optional APFS snapshot cleanup (list and trim local snapshots via `tmutil`) behind an “Expert” toggle with explicit warnings and support articles.

### Phase 5 — User Experience & Feedback Loop

- Update `SystemCleanupViewModel` to present confidence gauges, reason chips (“Not opened 180 days”, “App removed on 2025-01-12”), and direct launch of quarantine viewer.
- Provide dry-run reports exportable via share sheet, capturing space reclaimed projections and skipped rationale.
- Feed anonymized (opt-in) telemetry of score distributions into analytics so heuristic weights can be tuned without shipping updates; pair with synthetic regression suites inside `MacCleanerTests` to validate scoring and quarantine restores.

### Phase 6 — Continuous Coverage Enhancements

- Monitor new macOS releases for cache policy changes (e.g., Safari iCloud caches, Xcode Cloud artifacts) and add fixtures to `Preview Assets` for QA.
- Add plug-in architecture to `CleanupServiceRegistry` so third-party modules (e.g., Adobe, Unity) can register specialized cleaners while reusing the scoring/quarantine pipeline.
- Document extension points and publish API contracts for internal tooling.

This roadmap aligns our cleanup functionality with macOS best practices: score everything, quarantine first, respect SIP, and explain every action so power users can trust fully automated cleanups.

## Milestone F — Cleanup Intelligence & Safety

- [ ] Step 20 - Add cleanup telemetry, reason codes, and `FileManager.trashItem` support; expose guard decisions in the UI (see `cleanulogic.md` Phase 0).
- [ ] Step 21 - Ship `CleanupInventoryService` with enriched metadata (bundle IDs, Spotlight info) and expand scanners to browser caches, orphaned support folders, and installers (Phase 1).
- [ ] Step 22 - Implement the heuristic scoring engine, risk tiers, and duplicate detection, surfacing explanations per candidate (Phase 2).
- [ ] Step 23 - Introduce quarantine storage, manifest + checksum restore, and planned privileged passes via an `SMAppService` helper (Phase 3 & 4).
- [ ] Step 24 - Upgrade the cleanup UI with confidence gauges, quarantine browser, and exportable dry-run reports while adding regression tests for scoring/quarantine restores (Phase 5).
- [ ] Step 25 - Iterate on coverage (APFS snapshots, new macOS cache locations) and open the registry to plug-in cleaners backed by the shared pipeline (Phase 6).
