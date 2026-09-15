# Code conventions

This guide is the canonical coding policy for Perch.
Perch's product invariants remain in [`AGENTS.md`](../AGENTS.md).

## Tool-controlled rules

[`Package.swift`](../Package.swift) is authoritative for the Swift tools
version, language mode, supported platform, products, target dependencies, and
linked system libraries. The repository has no configured Swift formatter or
linter; match the surrounding code and review style manually rather than
claiming that `make verify` enforces formatting.

Use the existing SwiftPM and Makefile entry points. Do not add an Xcode project
or a parallel build or test path.

## Naming and organization

- Follow established Swift naming and access-control patterns in nearby code.
  Keep focused changes free of unrelated renames or file moves.
- Preserve the target boundaries declared in `Package.swift`:
  `PerchCore` contains shared parsing and assessment logic; `PerchBridge` is
  the hook-side executable; `Perch` contains the app, ingest, model, install,
  server, utility, and UI layers; `PerchMeta` and `PerchFuzz` are offline
  verification executables and are not shipped in the app bundle.
- Keep dependencies flowing through the declared target graph. Shared logic
  belongs in `PerchCore`; app or UI dependencies must not leak into it.

## Interfaces, types, and concurrency

- Preserve public APIs, hook payload compatibility, persisted schemas, and
  other externally observable contracts unless the requested change includes a
  documented compatibility change.
- Validate external JSON, filesystem state, and process output at the boundary
  that owns it. Reuse the existing `JSONValue`, tolerant payload accessors, and
  typed result models instead of introducing a parallel representation.
- Keep concurrency ownership explicit with the established `Sendable`,
  `@MainActor`, task, queue, or lock patterns. Do not weaken isolation merely to
  silence a compiler diagnostic.

## Error handling

- Use throwing APIs for failures a caller can handle. Catch errors where the
  app can recover, add useful context, or translate them into an existing
  user-visible status; otherwise propagate them.
- Use `try?` only for an intentional best-effort probe or cleanup with a safe,
  understood fallback. Do not silently turn an unexpected failure into success.
- Preserve atomic-write, permission, and failure-reporting behavior around
  configuration and persisted state.

## Tests

- Test observable behavior and relevant failure paths. Add a regression case
  for a bug fix when practical.
- Perch uses its in-binary selftest, not XCTest. Put focused suites alongside
  the existing `Sources/Perch/App/*Tests.swift` files, register new entry points
  in `Selftest.run()`, and run them through `make test`.
- Keep normal checks deterministic and offline. Do not require credentials,
  network services, or developer-machine state.
- After any `RiskAssessor` change, run `make meta` in addition to the selftest.
  Preserve the hard invariants and anchor rule in `AGENTS.md`.

## Dependencies

Perch currently has no third-party runtime package dependency. Prefer the Swift
standard library, Foundation, and existing system frameworks when suitable.
Add a dependency only for a concrete project need, update the SwiftPM metadata
and lockfile policy as applicable, and document material build or distribution
impact.

## Verification and coverage

Run `make verify` before a commit. It executes:

- `make fitness`: source checks for Perch's read-only boundary and safe command
  anchors.
- `make test`: a release build followed by the in-binary selftest.
- `make meta`: `RiskAssessor` metamorphic monotonicity checks.
- `make commitlint-test`: behavioral tests for the commit-range checker.

These checks cover compilation, tested behavior, the two mechanized product
invariants, risk monotonicity, and commit-checker behavior. They do not enforce
formatting, naming, module placement, API compatibility, error-handling quality,
dependency necessity, test adequacy, or the accuracy of documentation. Review
those rules manually in the changed scope.
