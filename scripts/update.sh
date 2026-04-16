#!/usr/bin/env bash
# Update sources.json to the latest pingdotgg/t3code release.
# Exits 0 on success (whether or not anything changed).
# Prints the new version to stdout on the first line if an update was applied.
set -euo pipefail

REPO="pingdotgg/t3code"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources.json"

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need jq
need curl

if command -v gh >/dev/null; then
  release_json=$(gh api "repos/$REPO/releases/latest")
else
  release_json=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$REPO/releases/latest")
fi

tag=$(jq -r '.tag_name' <<<"$release_json")
version="${tag#v}"
current=$(jq -r '.version' "$SOURCES")

if [[ "$version" == "$current" ]]; then
  echo "already up to date: $version" >&2
  exit 0
fi

echo "updating: $current -> $version" >&2

# Expected asset name patterns per nix system.
declare -A PATTERNS=(
  [x86_64-linux]="T3-Code-${version}-x86_64.AppImage"
  [aarch64-darwin]="T3-Code-${version}-arm64.zip"
  [x86_64-darwin]="T3-Code-${version}-x64.zip"
)

tmp=$(mktemp)
jq --arg v "$version" '.version = $v' "$SOURCES" >"$tmp"

for sys in "${!PATTERNS[@]}"; do
  name="${PATTERNS[$sys]}"
  digest=$(jq -r --arg n "$name" \
    '.assets[] | select(.name == $n) | .digest' <<<"$release_json")
  if [[ -z "$digest" || "$digest" == "null" ]]; then
    echo "error: asset $name not found in release $tag" >&2
    exit 1
  fi
  sha="${digest#sha256:}"
  jq --arg s "$sys" --arg n "$name" --arg h "$sha" \
    '.assets[$s] = {name: $n, sha256: $h}' "$tmp" >"$tmp.new"
  mv "$tmp.new" "$tmp"
done

mv "$tmp" "$SOURCES"
echo "$version"
