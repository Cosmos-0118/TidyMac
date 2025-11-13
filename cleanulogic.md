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
