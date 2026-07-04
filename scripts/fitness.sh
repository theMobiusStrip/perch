#!/usr/bin/env bash
# Executable fitness functions for the PerchCore invariants CLAUDE.md states in
# prose. Pure source scan — no build — so it runs instantly as a pre-commit
# tripwire and a CI gate (the heavy behavioural gates are selftest + `make meta`).
#
#   INV1  Command-position anchors in RiskAssessor use `^\s*`, never a bare `^`.
#         A bare `^` alternative lets a single leading space bypass detection.
#         This shipped once (v0.6.0, `seg`/`sudoInvocation`) and recurred in three
#         more anchors — a prose warning didn't hold, so it's mechanised here.
#         Flags a `^` anchor alternative (`^|` or `^)`) that is NOT a negated
#         char class (`[^`) and NOT already `^\s`.
#
#   INV2  Perch is read-only by construction: it never writes a decision back.
#         `permissionDecision` / `hookSpecificOutput` are the Claude Code hook
#         wire fields that let a hook allow/deny an action; their appearance
#         anywhere in the sources means an enforcement path was introduced.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
ra="Sources/PerchCore/RiskAssessor.swift"

# INV1 — bare command-position anchor
anchors="$(perl -ne 'print "  $ARGV:$.: $_" if /(?<!\[)\^[|)]/' "$ra")"
if [ -n "$anchors" ]; then
  echo "FITNESS FAIL — bare ^ command anchor (needs ^\\s*; one leading space bypasses it):"
  echo "$anchors"
  fail=1
fi

# INV2 — no enforcement emission (read-only invariant)
decision="$(grep -rnE 'permissionDecision|hookSpecificOutput' Sources/ || true)"
if [ -n "$decision" ]; then
  echo "FITNESS FAIL — Perch is read-only, but a hook-decision field appears:"
  echo "$decision"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "fitness: invariants hold (no bare-^ anchor, read-only)"
fi
exit "$fail"
