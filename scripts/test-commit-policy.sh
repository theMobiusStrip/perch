#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$script_dir/check-commits.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/perch-commit-policy.XXXXXX")"
repository="$scratch/repository"
trap 'rm -rf "$scratch"' EXIT

git init -q -b main "$repository"
git -C "$repository" config user.name "Commit Policy Test"
git -C "$repository" config user.email "commit-policy@example.invalid"
git -C "$repository" config commit.gpgsign false

git -C "$repository" commit -q --allow-empty -m "chore: establish baseline"
base="$(git -C "$repository" rev-parse HEAD)"

git -C "$repository" commit -q --allow-empty \
  -m "fix(ci): enforce commit messages" \
  -m "Co-authored-by: Codex <noreply@openai.com>"
valid="$(git -C "$repository" rev-parse HEAD)"
"$checker" range "$base" "$valid" "$repository"

git -C "$repository" switch -q -c fake-merge "$base"
git -C "$repository" commit -q --allow-empty \
  -m "Merge pull request #1 from example/topic"
git -C "$repository" commit -q --allow-empty -m "fix: follow up safely"
fake_merge="$(git -C "$repository" rev-parse HEAD)"
if "$checker" range "$base" "$fake_merge" "$repository"; then
  echo "commit policy test: a merge-shaped authored message passed" >&2
  exit 1
fi

git -C "$repository" switch -q main
git -C "$repository" commit -q --allow-empty -m "fix: keep main change"
git -C "$repository" switch -q -c side "$valid"
git -C "$repository" commit -q --allow-empty -m "feat: add side change"
git -C "$repository" switch -q main
git -C "$repository" config core.hooksPath "$script_dir/../.githooks"
git -C "$repository" merge -q --no-ff side -m "Generated merge message"
merge="$(git -C "$repository" rev-parse HEAD)"
"$checker" range "$valid" "$merge" "$repository"

valid_message="$scratch/valid-message"
long_message="$scratch/long-message"
printf '%s\n' "feat!: remove legacy hook format" > "$valid_message"
printf '%s\n' "fix: 1234567890123456789012345678901234567890123456" > "$long_message"
"$checker" message-file "$valid_message"
if "$checker" message-file "$long_message"; then
  echo "commit policy test: an overlong header passed" >&2
  exit 1
fi

echo "commit policy tests passed"
