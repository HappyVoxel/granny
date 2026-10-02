#!/usr/bin/env bash
# Prints the next release version, or nothing when the commits since the
# last v* tag are not release-worthy (docs, chore, ci, tests).
#
# Pre-1.0 the line ships patch releases: any releasable change bumps the
# patch, a breaking change bumps the minor. From 1.0 on Conventional
# Commits decide (breaking -> major, feat -> minor, fix/perf/revert -> patch).
set -euo pipefail
cd "$(dirname "$0")/.."

latest="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
base="${latest#v}"
if [ -z "$latest" ]; then
  base="0.0.0"
  range="HEAD"
else
  range="$latest..HEAD"
fi

subjects="$(git log "$range" --format='%s')"
bodies="$(git log "$range" --format='%B')"

if ! printf '%s\n' "$subjects" | grep -qE '^(feat|fix|perf|revert)(\([^)]*\))?!?: '; then
  echo "next-version: no releasable commits since ${latest:-the beginning}" >&2
  exit 0
fi

breaking=0
if printf '%s\n' "$subjects" | grep -qE '^[a-z]+(\([^)]*\))?!: '; then
  breaking=1
elif printf '%s\n' "$bodies" | grep -q 'BREAKING[ -]CHANGE:'; then
  breaking=1
fi

IFS=. read -r major minor patch <<< "$base"
if [ "$major" -eq 0 ]; then
  if [ "$breaking" -eq 1 ]; then
    minor=$((minor + 1))
    patch=0
  else
    patch=$((patch + 1))
  fi
elif [ "$breaking" -eq 1 ]; then
  major=$((major + 1))
  minor=0
  patch=0
elif printf '%s\n' "$subjects" | grep -qE '^feat(\([^)]*\))?: '; then
  minor=$((minor + 1))
  patch=0
else
  patch=$((patch + 1))
fi
echo "$major.$minor.$patch"
