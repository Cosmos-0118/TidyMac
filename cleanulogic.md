# MacOS Safe Cache & Orphaned File Cleaner: Heuristics & Policy Specification

## Goals & Principles

- Detect likely cache, temporary, or orphaned junk files with **high precision**.
- Score confidence numerically per candidate file/folder to guide actions (automated, review, or ignore).
- Prefer **move-to-quarantine** instead of deletion. Maintain manifest & checksum for all actions, allowing easy restore.
- Support full dry-run, undo, and clear reason explanations for each action.
- Respect **ownership, permissions, processes, Apple sandboxes**, and never operate in System Integrity Protected (SIP) areas.

---

## Scan Targets

1. App caches: `~/Library/Caches/*`, `/Library/Caches/*`, app-specific caches.
2. Browser & webview caches: Safari, Chrome, Firefox.
3. Temporary files: `/tmp`, `/var/folders/*`, `~/Library/Containers/*/Data/Library/Caches`.
4. Old logs: `~/Library/Logs`, `/var/log` (only user logs).
5. Orphaned app support: `~/Library/Application Support/*` (if app uninstalled).
6. Orphaned preferences: `~/Library/Preferences/*` (no matching app).
7. Old installers: DMG/PKG in Downloads/Desktop.
8. Orphaned device/backups: e.g., old iOS backups in `~/Library/Application Support/MobileSync/Backup`.
9. Leftover app bundles outside `/Applications` with lingering data.
10. Large unused files: rarely accessed large files, e.g., disk images or media.
11. Duplicates: files with identical checksums.
12. Broken symlinks & zero-length files.
13. Xcode derived data, simulators: `~/Library/Developer/*`.
14. Unused language packs in `.app` bundles (user-confirmation required).

---

## Heuristics & Detection Signals

For each file/folder, collect these signals:

- **Age:** mtime, atime; preferentially target files not accessed in 30+ days.
- **Size:** Prefer larger files for cleanup candidates.
- **Ownership/Permissions:** Only user-owned by default; flag or skip root/system-owned.
- **Process Locks:** Check with `lsof`—never touch open files.
- **App Association:** Is associated app installed and/or recently used? (via receipts and app bundle scans).
- **Code Signatures/Receipts:** Use `pkgutil`, `codesign` for bundles/apps.
- **Quarantine Flags:** Check `xattr` for quarantine state.
- **Known Safe Paths:** Lower risk in common cache/temp/log areas.
- **File Type:** Flags if extension matches {`.tmp`, `.log`, `.cache`, `.dmg`} etc.
- **Duplication:** Multiple same-checksum files? Prefer to keep the canonical/latest.
- **User Excludes:** User-configured pin/exclude overrides.
- **Backup Status:** If flagged for backup (Time Machine/iCloud), do not act without user explicit consent.
- **Filesystem Flags:** Never act on SIP, immutable, system files or locked flags.

---

## Confidence Scoring

Compute a [0…100] score per candidate—**explainable, weighted by key signals:**

- `ageScore = clamp( (days_since_access/90)*30, 0, 30 )`
- `sizeScore = clamp( log2(size_bytes)*2, 0, 25 )`
- `ownerScore = 10` if user-owned; else `0`
- `processScore = -40` if open by any process
- `appExistScore = -20` if app is still installed/recently used; `+20` if orphaned
- `pathPatternScore = +15` for known low-risk paths
- `fileTypeScore = +10` for temp/log/Dmg/etc.
- `duplicateScore = +8` if duplicate (do not double-count size)
- `quarantineFlagScore = +5` if flagged as quarantine

Example (Python pseudocode):

**Thresholds:**

- `Score ≥ 70`: Auto-move to quarantine (not delete).
- `50 ≤ Score < 70`: Prompt user for review.
- `30 ≤ Score < 50`: Suggest, require action.
- `< 30`: Log only; never act.

---

## Action Policy (Safety-First)

1. **Dry-run/report only** at first; preview estimated recoverable space and likely risk.
2. **Auto-quarantine** for high-confidence; show manifest and restore options.
3. **Manifest+checksum** for all actions; store quarantine at `~/Library/Application Support/<YourApp>/Quarantine/<timestamp>/`, retaining for 30 days by default.
4. **Restore** always available—move back by manifest and verify checksum.
5. **No delete until** after quarantine retention (default 30 days) or explicit user request.
6. **Undo/restore** must be simple and log every action.
7. **Full audit log** with opt-in telemetry for algorithm improvement.

---

## Critical Protections/Risk Mitigation

- Never operate in SIP-protected or system locations.
- Do not touch root/system ownership without opt-in and password.
- Never act on open/process-locked files.
- Avoid removing items from Mail, Photos, or SQLite-DBs of known apps.
- Respect Time Machine/iCloud flags and user exclusions at all times.
- Use Authorization Services for any sensitive/bulk change.

---

## UX & Testing Guidance

- Provide 3 reasons per candidate for transparency (“last used 170 days ago”, “not linked to installed app”).
- Show before/after space estimates.
- Offer profile controls: Safe, Moderate, Aggressive, Expert.
- Visual logs, per-directory keeps/ignores.
- Test on synthetic user accounts and get opt-in feedback per action.

---

## Current Implementation Audit (Nov 2025)

- `SystemCacheCleanupService` enumerates caches, logs, and temp roots, but emits only `CleanupItem` lists without confidence scores, reason metadata, or last-access provenance. It deletes in place after a guard check, skipping quarantine or trash workflows.
- `LargeFileScanner` performs a shallow heuristic (size ≥ 50 MiB, age ≥ 30 days) limited to a few user folders. It lacks duplicate detection, file-type heuristics, and association checks against installed apps or Time Machine snapshots.
- `XcodeCacheCleaner` treats every derived-data child equally, so it cannot prioritize stale simulator bundles versus active previews. All three services rely on the `DeletionGuard` allow/deny list but do not consult process locks (`lsof`/`FSEvents`), code signatures, or SIP awareness beyond error handling.
- There is no shared scoring engine, quarantine manifest, reason codes, or undo pipeline—core expectations outlined above. Privileged deletions escalate late (after failures) rather than orchestrating a planned privileged pass.

---

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
