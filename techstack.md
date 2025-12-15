# TidyMac Tech Stack

## Product Goals

- Deliver a macOS-native desktop experience that helps users monitor system health, reclaim disk space, and remove unwanted developer tooling artifacts.
- Keep the footprint lightweight, sandbox-aware, and respectful of macOS security and privacy expectations.
- Favor technologies that are maintainable by a small team and align with Apple's platform roadmap.

## Current Implementation Snapshot

- SwiftUI app entry point in `TidyMac/TidyMacApp.swift` with navigation defined in `Views/ContentView/ContentView.swift`.
- Feature views (Dashboard, System Cleanup, Large Files Finder, Uninstaller, Developer Tools) implemented as SwiftUI views with synchronous model calls.
- Model layer under `TidyMac/Model` uses Foundation APIs (`FileManager`, `ByteCountFormatter`) and low-level Mach calls for CPU, memory, and disk statistics.
- No dedicated service layer, dependency injection, or asynchronous error handling around privileged file operations.

## Proposed Layered Stack

| Layer                  | Primary Technologies                                                                                              | Rationale                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| UI & Navigation        | SwiftUI 5, AppKit interop via `NSViewRepresentable`, SF Symbols                                                   | Modern macOS look, adaptive layouts, access to AppKit-only controls when needed     |
| State Management       | Swift Concurrency (`@MainActor` views, `Task`, `AsyncSequence`), Combine for publishers where needed              | Keeps UI responsive during long-running file operations                             |
| Domain Services        | Swift modules (SPM targets) encapsulating storage analysis, cleanup orchestration, uninstall logic                | Testable separation between UI and system-touching code                             |
| System Integrations    | `FileManager`, `DiskArbitration`, `Process`, `NSWorkspace`, Authorization Services (`SMJobBless`)                 | Ensure privileged actions (e.g., deleting system files) follow macOS security model |
| Background Work        | `AsyncStream`, `OperationQueue`, `ProcessInfoThermalState`, `os_signpost` instrumentation                         | Controlled resource usage, progress reporting, diagnostics                          |
| Persistence & Settings | `AppStorage`/`UserDefaults`, lightweight JSON via `Codable`                                                       | Store user preferences, cleanup history, exclusion lists                            |
| Telemetry & Logging    | `os.Logger`, unified logging categories, optional analytics via App Center (opt-in)                               | Production diagnostics without third-party loggers                                  |
| Build & Modules        | Xcode 16 project, Swift Package Manager for shared modules, fastlane for CI/CD                                    | Repeatable builds, automation for notarization and distribution                     |
| Testing & QA           | XCTest, XCUITest, snapshot testing with `pointfreeco/swift-snapshot-testing`, integration tests via shell scripts | Covers regression risk for UI and destructive operations                            |

## Component Breakdown

### UI Layer

- Compose primary navigation with `NavigationSplitView` (macOS 14+) to better fit sidebar metaphors.
- Reuse `ProgressView`, `Gauge`, and custom charts via Swift Charts for monitoring dashboards.
- Bridge AppKit components (e.g., `NSOpenPanel`, `NSTextView`) when richer interactions or file pickers are required.

### Presentation & State

- Encapsulate feature logic in view models annotated with `@Observable` or `ObservableObject` running under `@MainActor`.
- Use structured concurrency to run cleanup scans via `Task { await cleanupService.run() }` with cancellation tokens and progress reporting through `AsyncStream`.
- Adopt dependency injection (simple protocol + initializer injection) to ease testing and future service swaps.

### Domain Services

- Split current `Model` functions into dedicated modules:
  - `StorageService` for disk statistics and byte formatting helpers.
  - `CleanupService` coordinating temporary file removal, large file detection, and tool cache cleanup.
  - `UninstallService` leveraging `NSWorkspace` to locate apps and `Authorization Services` for privileged deletes.
- Provide dry-run modes and exclusion lists to guard against accidental data loss.

### System Integrations & Privileges

- Use `Security` framework (`AuthorizationCreate`, `SMJobBless`) to escalate privileges for operations touching `/Applications` or root-owned directories, instead of deleting with the app sandbox.
- Adopt `FileProvider` or `BookmarkData` for user-consented directory access inside the sandbox.
- For performance metrics, switch to `ProcessInfo`, `host_statistics64`, or `OSLogStore` depending on accuracy needs and energy footprint.

### Background Execution & Scheduling

- Leverage `BGTaskScheduler` for maintenance tasks triggered while the app is in background (where sandbox allows).
- Wrap destructive tasks in `Progress` + `NSProgress` for bridged UI updates and to expose cancellation.

### Persistence & Configuration

- Persist user settings (thresholds, ignored folders) using `AppStorage` for simple toggles and `FileManager` + `Codable` for structured lists under `Application Support`.
- Cache scan results in memory with `NSCache` to avoid rescanning during a single session.

### Observability & Diagnostics

- Define `OSLog` categories (`monitoring`, `cleanup`, `uninstall`) and surface errors to an in-app diagnostics panel.
- Optional integration with Apple Crash Reports or App Center for crash and usage telemetry (respecting user opt-in).

### Tooling & Delivery

- Enable SwiftLint/SwiftFormat via Swift Package to enforce code style in CI.
- Configure `fastlane` to automate unit tests, UI tests, code signing, notarization, and DMG/PKG packaging.
- Keep third-party dependencies minimal; when necessary, add via Swift Package Manager (`Package.swift`).

### Testing Strategy

- Unit tests for each service to validate file filtering, cleanup safety, and metric calculations.
- UI snapshot tests for main screens to catch layout regressions.
- Integration tests using a temporary sandboxed directory tree to simulate cleanup scenarios without touching the real file system.

## Migration Roadmap

1. **Refactor Models into Services**: Extract logic from SwiftUI views into protocol-backed services under `Sources/Core` SPM module.
2. **Adopt Async APIs**: Replace synchronous file operations with async variants, add progress publishers, and surface cancellation UI.
3. **Introduce View Models**: Create view models per feature with dependency injection for services and analytics.
4. **Add Observability**: Instrument with `os.Logger`, wire in error reporting UI, and set up xcpretty + fastlane for CI logs.
5. **Harden Privileged Actions**: Implement authorization prompts, sandbox exceptions, and user confirmation flows for deletions.
6. **Expand Test Coverage**: Populate `TidyMacTests` and `TidyMacUITests` with scenarios covering cleanup success/failure paths.

## Reference Apple Frameworks & Docs

- [SwiftUI on macOS](https://developer.apple.com/documentation/swiftui)
- [File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/Introduction/Introduction.html)
- [Authorization Services Programming Guide](https://developer.apple.com/documentation/security/authorization_services)
- [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks)
- [OSLog](https://developer.apple.com/documentation/os/oslog)
