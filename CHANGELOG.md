# Changelog

Notable changes to Perch are documented here. Dates use `YYYY-MM-DD`.

## [Unreleased]

### Changed

- Made tagged builds draft releases until their hardware-signed checksum is
  uploaded and the release is ready to publish.

## [1.7.0] - 2026-09-12

### Added

- Added an Insights screenshot to the README showcase.
- Added Claude terminal-failure and compaction events, plus Codex interruption
  and session-end tracking.
- Added compatibility checks across supported macOS generations.
- Added a `Quit Perch` action to the expanded notch.
- Added Conventional Commits enforcement for local hooks and CI.
- Added CI-generated build-provenance attestations for release DMGs alongside
  detached maintainer signatures for their checksums.

### Changed

- Updated release setup guidance for Monitoring Setup and Live verification.

### Fixed

- Score sensitive file targets in Codex patches, including relative paths,
  deletions, and rename destinations, without treating patch contents as commands.
- Verify current hook identities and enabled state across desktop and CLI
  runtimes instead of relying on stored trust-record counts.
- Keep terminal failure and session-end state from being undone by late events.
- Isolate general Codex quota snapshots from other limits and older replayed
  records, clearing unavailable windows without mixing snapshots.

## [1.6.0] - 2026-07-23

### Added

- Added Local Insights with offline 24-hour, 7-day, and 30-day detection
  timelines and breakdowns by finding, agent, tool, and session.
- Added a local SQLite store that retains minimal caution and danger metadata
  for 30 days and restores the past hour's security posture after restart.
- Added `make verify` as the complete local fitness, selftest, and metamorphic
  verification gate.

### Changed

- Published the versioned, read-only detection storage contract.

### Fixed

- Made detection identity construction independent of hostname resolution
  during app startup.

## [1.5.0] - 2026-07-22

### Added

- Added monitoring health that verifies the bridge, socket, agent
  configuration, hook trust, and live event delivery separately.
- Added guided Monitoring Setup and expanded Doctor diagnostics for installing
  and repairing Claude Code and Codex integrations.
- Added notification preferences, deep-linked notification actions, and a
  detailed Recent Detections view.

### Changed

- Made monitoring gaps actionable in the notch and menu bar, with health state
  reflected in the Perch bird and collapsed notch.

## [1.4.0] - 2026-07-20

### Changed

- Refreshed the notch panel with shared semantic colors, card surfaces, agent
  icons, state pills, and glance rows.
- Improved showcase rendering for sharper screenshots.

## [1.3.0] - 2026-07-15

### Added

- Added a read-only cross-project worktree audit with active, reclaimable,
  review, and orphaned classifications.
- Added worktree size reporting, a dedicated window, a notch summary,
  copy-only cleanup commands, and `--worktree-report`.

### Changed

- Made the notch token summary open the Token Usage window.
- Documented the optional update check as Perch's only network call.

## [1.2.0] - 2026-07-15

### Added

- Added an optional menu-bar update check that compares GitHub releases and
  opens the release page without downloading or installing anything.

## [1.1.0] - 2026-07-15

### Added

- Added support for Claude Code's `PostToolUseFailure` hook event so failed
  tool calls complete correctly in the session timeline.
- Added support for Codex 0.144 multi-agent rollout files without showing
  helper subagents as peer sessions.

## [1.0.0] - 2026-07-03

### Added

- Released the first stable version of the read-only macOS notch and menu-bar
  monitor for Claude Code and Codex.
- Added offline risk scoring, dangerous-action notifications, live session and
  token views, security posture scoring, and persistence-surface monitoring.
- Added deterministic selftests, a metamorphic risk-scoring oracle, and a
  crash and hang fuzzer.

### Fixed

- Closed leading-whitespace command-anchor detection bypasses.
- Bounded memory use while scanning token-usage files.

[Unreleased]: https://github.com/theMobiusStrip/perch/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/theMobiusStrip/perch/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/theMobiusStrip/perch/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/theMobiusStrip/perch/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/theMobiusStrip/perch/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/theMobiusStrip/perch/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/theMobiusStrip/perch/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/theMobiusStrip/perch/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/theMobiusStrip/perch/releases/tag/v1.0.0
