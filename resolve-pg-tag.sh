#!/usr/bin/env bash
# Print the newest theseus-rs/postgresql-binaries release tag for a
# PostgreSQL major version (e.g. 17 -> 17.12.0).
#
# Usage: ./resolve-pg-tag.sh <pg-major>

set -euo pipefail

PG_MAJOR="${1:?usage: $0 <pg-major>}"

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

tags=""
for page in 1 2 3 4 5 6 7 8 9 10; do
  body=$(curl -fsSL --retry 5 --retry-all-errors "${auth[@]}" "https://api.github.com/repos/theseus-rs/postgresql-binaries/releases?per_page=100&page=${page}")
  page_tags=$(printf '%s' "$body" | grep -oE '"tag_name": *"[0-9.]+"' | grep -oE '[0-9]+(\.[0-9]+)+' || true)
  [ -n "$page_tags" ] || break
  tags="$tags"$'\n'"$page_tags"
done

tag=$(printf '%s\n' "$tags" | grep -E "^${PG_MAJOR}\.[0-9]+\.[0-9]+$" | sort -V | tail -1 || true)
if [ -z "$tag" ]; then
  echo "no theseus-rs release found for PostgreSQL ${PG_MAJOR}" >&2
  exit 1
fi
echo "$tag"
