# Perch — agent guide

macOS notch app that monitors Claude Code / Codex sessions via their hook
events. SwiftPM only — there is no Xcode project.

## Build & verify

- `make build` — release build of all targets.
- `make test` — THE test entry: builds, then runs the in-binary selftest
  (`Perch --selftest`). There is no XCTest target and `swift test` does not
  work; the selftest is in-binary by design so it runs on machines without
  XCTest and inside the release binary itself. All suites must pass with
  0 failures before any commit.
- `make meta` — metamorphic oracle over `RiskAssessor.assess`. Runs in CI on
  every push/PR; exit 2 means a monotone violation (a strictly-more-dangerous
  rewrite lowered the risk level — a detection bypass). Run it after ANY
  change to RiskAssessor.
- `make fuzz [N=count]` — deterministic crash/hang fuzzer over the parse +
  scoring surface. Manual only (throughput is regex-bound); a reported index
  reproduces exactly with `.build/release/PerchFuzz --replay N`.
- `make fitness` — build-free source scan that mechanises the hard invariants
  below (bare-`^` command anchor; read-only). Runs in CI before the build and
  as the pre-commit hook; `make hooks` installs the hook (once per clone, since
  git won't auto-run repo hooks).
- `make app` — assemble ad-hoc-signed `dist/Perch.app`.

## Hard invariants

- **Perch is read-only.** It observes and scores; it never approves, denies,
  or blocks an agent action. There is no decision code path. Do not add
  approval, allow-listing, or blocking features in any form. `make fitness`
  fails if a `permissionDecision`/`hookSpecificOutput` hook-decision field
  appears anywhere in the sources.
- **Command-position anchors need `^\s*`, not bare `^`.** A bare `^` in a
  command-position regex alternative lets a single leading space bypass
  detection. This shipped as a real bypass once and then recurred in three more
  anchors — so it's mechanised: `make fitness` fails on any bare `^` anchor
  (structural, build-free), and `make meta` catches the class behaviourally.
  Audit any new anchor in RiskAssessor for it.

## Layout

- `Sources/PerchCore` — hook parsing, risk scoring, stores. Pure logic;
  everything here is exercised by the selftest.
- `Sources/Perch` — the app (UI, tailers, scanners, CLI entry points).
- `Sources/PerchBridge` — `perch-bridge`, the hook-side binary.
- `Sources/PerchMeta`, `Sources/PerchFuzz` — offline oracles; built as
  executables but never shipped in the app bundle.

## Conventions

- Commits: imperative subject ≤50 chars; body only when the why isn't
  obvious. No tool attributions/footers, no process narrative, no
  conversation-context leak (sources, durations, prompts) in commit or PR text.
- Public repo: never commit or push private data — no PLAN.md, machine
  details, credentials, or internal paths.
- Releases are built by CI from `v*` tags (`release.yml`); never hand-build
  or re-sign release artifacts locally.
