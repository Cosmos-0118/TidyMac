# MacCleaner

A SwiftUI macOS app that monitors system health, finds reclaimable storage, and removes developer cruft with guardrails for safety.

## Overview

- Native SwiftUI experience with a design system theme and `NavigationSplitView` sidebar.
- Features: dashboard metrics, system cleanup, large/old file finder, app uninstaller, and developer tooling hygiene.
- Safety first: all deletions are filtered through `DeletionGuard`, prompt for elevated privileges when needed, and show recovery notes.

## Core Features

- **Dashboard**: CPU, memory, disk, battery, and uptime snapshot with live metrics streaming via `SystemMonitorService`.
- **System Cleanup**: Scans caches, logs, temp folders, app support leftovers, and simulator caches; review by category, select/deselect, then delete with progress tracking.
- **Large & Old Files**: Maps home/Downloads/Desktop/Movies for oversized or stale files, supports exclusions, and handles Full Disk Access gracefully.
- **Uninstaller**: Groups installed apps by location (system/user), shows bundle IDs and paths, and uninstalls with admin prompts when required.
- **Developer Tools**: One-click actions for DerivedData, Xcode/VS Code caches, simulator caches/devices, toolchain logs, and custom toolchains.
- **Diagnostics**: Toolbar "ladybug" button opens a diagnostics panel; `UITEST_SEED_DIAGNOSTICS=1` seeds data for UI tests.

## Safety & Permissions

- **DeletionGuard** prevents risky paths; privileged deletion paths are routed through `PrivilegedDeletionHelper` / `PrivilegedDeletionService`.
- **Full Disk Access**: Some scans (large files, caches, uninstall) need it. Go to _System Settings → Privacy & Security → Full Disk Access_ and add MacCleaner.
- **Dry-run style UX**: You review categories and selections before deleting; overlays keep destructive actions obvious.

## Requirements

- macOS Sonoma or later (tested on Apple Silicon).
- Xcode 15+ (Swift 5.10+). Uses the Xcode project `MacCleaner.xcodeproj`.
- Optional: `xcbeautify` for prettier build output when using the helper script.

## Quick Start

1. Open `MacCleaner.xcodeproj` in Xcode and select the **MacCleaner** scheme.
2. Run the app (⌘R) or use the helper script:

   ```sh
   ./scripts/build_and_run.sh
   ```

3. Grant Full Disk Access if prompted so scans can traverse user and system locations.

## Running Tests

- Unit/UI tests are under `MacCleanerTests/` and `MacCleanerUITests/`.
- From the command line:

  ```sh
  xcodebuild \
    -scheme MacCleaner \
    -project MacCleaner.xcodeproj \
    -destination 'platform=macOS' \
    test
  ```

## Project Layout

- `MacCleaner/Views/` – SwiftUI screens (`Dashboard`, `SystemCleanup`, `LargeFilesFinder`, `Uninstaller`, `DeveloperTools`, `ContentView`).
- `MacCleaner/ViewModels/` – State holders for each feature area.
- `MacCleaner/Services/` – Domain services (cleanup orchestration, inventory, large file scanning, developer ops).
- `MacCleaner/Model/` – Core data models (apps, cleanup categories, storage info, deletion helpers).
- `MacCleaner/Utilities/` – Shared helpers (diagnostics, design system palette, deletion guards).
- `scripts/` – Automation like `build_and_run.sh`.

## Key Services

- `SystemCacheCleanupService` – Comprehensive cache/log/temp discovery with inventory of orphaned support files and browser caches.
- `FileSystemLargeFileScanningService` – Async scanner with progress callbacks, permission-aware messaging, and guarded deletions.
- `CleanupInventoryService` – Finds orphaned preferences/app support/installers to surface in cleanup categories.
- `DeveloperOperationsService` – Implements DerivedData/Xcode/VS Code/simulator/toolchain maintenance tasks with privileged fallbacks.

## Troubleshooting

- **Scan shows few results**: Confirm Full Disk Access is granted; some system paths are hidden without it.
- **Uninstall fails**: App may be in a protected location (e.g., `/Applications`); rerun with admin approval when prompted.
- **Build noise**: Install `xcbeautify` (`brew install xcbeautify`) to clean Xcode build logs when using the script.

## Contributing Notes

- Keep destructive changes behind user confirmation and progress overlays.
- Prefer async work off the main actor for scans; surface progress via view models.
- Add tests in `MacCleanerTests` for new services and `MacCleanerUITests` for UI flows.
