#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
commitlint="$repo_root/tools/commitlint/node_modules/.bin/commitlint"
config="$repo_root/tools/commitlint/commitlint.config.mjs"

usage() {
  echo "usage: $0 message-file <path>" >&2
  echo "       $0 range <base> <head> [repository]" >&2
  exit 64
}

if [[ ! -x "$commitlint" ]]; then
  echo "commitlint is not installed; run 'make commitlint-install'" >&2
  exit 69
fi

mode="${1:-}"
case "$mode" in
  message-file)
    [[ $# -eq 2 ]] || usage
    exec "$commitlint" --config "$config" --edit "$2"
    ;;
  range)
    [[ $# -eq 3 || $# -eq 4 ]] || usage
    base="$2"
    head="$3"
    repository="${4:-$repo_root}"
    ;;
  *)
    usage
    ;;
esac

for revision in "$base" "$head"; do
  if ! git -C "$repository" rev-parse --verify --quiet "${revision}^{commit}" >/dev/null; then
    echo "commit policy: unresolved revision: $revision" >&2
    exit 65
  fi
done

failed=0
while IFS= read -r commit; do
  parent_line="$(git -C "$repository" rev-list --parents -n 1 "$commit")"
  read -r -a commit_and_parents <<< "$parent_line"
  if [[ ${#commit_and_parents[@]} -gt 2 ]]; then
    echo "commit policy: skipping merge ${commit:0:12}"
    continue
  fi

  echo "commit policy: checking ${commit:0:12}"
  if ! git -C "$repository" show -s --format=%B "$commit" |
    "$commitlint" --config "$config"; then
    failed=1
  fi
done < <(git -C "$repository" rev-list --reverse "$base..$head")

exit "$failed"
