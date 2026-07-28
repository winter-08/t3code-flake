#!/usr/bin/env bash
# Update sources.json to the latest pingdotgg/t3code release per channel.
#
#   ./scripts/update.sh                # both channels
#   ./scripts/update.sh nightly        # just one
#
# Exits 0 on success (whether or not anything changed).
# Prints "<channel> <version>" to stdout for each channel that was updated.
set -euo pipefail

REPO="pingdotgg/t3code"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources.json"

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need jq
need curl

channels=("$@")
if [[ ${#channels[@]} -eq 0 ]]; then
  channels=(stable nightly)
fi
for chan in "${channels[@]}"; do
  case "$chan" in
    stable | nightly) ;;
    *) echo "unknown channel: $chan (expected stable or nightly)" >&2; exit 1 ;;
  esac
done

api() {
  local path="$1"
  if command -v gh >/dev/null; then
    gh api "$path"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/$path"
  fi
}

# Asset name patterns per nix system, as a jq object keyed by system.
patterns() {
  jq -n --arg v "$1" '{
    "x86_64-linux":   "T3-Code-\($v)-x86_64.AppImage",
    "aarch64-darwin": "T3-Code-\($v)-arm64.zip",
    "x86_64-darwin":  "T3-Code-\($v)-x64.zip"
  }'
}

missing_assets() {
  local version="$1" release_json="$2"
  jq -r --argjson want "$(patterns "$version")" '
    [ .assets[].name ] as $have
    | [ $want[] | select(. as $n | $have | index($n) | not) ]
    | join(", ")' <<<"$release_json"
}

# Prints "<version>\t<release json>" for the newest usable release on a channel.
# A build can publish partial assets if one platform's job failed, so walk back
# through recent releases and take the newest complete one.
resolve_channel() {
  local chan="$1" filter candidates page allfile page_json
  case "$chan" in
    stable)  filter='select(.prerelease | not)' ;;
    nightly) filter='select(.prerelease) | select(.tag_name | test("-nightly\\."))' ;;
  esac

  # Nightlies land several times a day and far outnumber stable releases, so a
  # stable tag can sit many pages deep. Page until we have a few candidates.
  # Accumulate via a temp file, not a jq argument: release JSON grows past the
  # kernel's per-argument size limit ("Argument list too long"), and keep only
  # the fields we use so the accumulator stays small.
  allfile=$(mktemp)
  echo '[]' >"$allfile"
  for page in 1 2 3 4 5; do
    page_json=$(api "repos/$REPO/releases?per_page=100&page=$page")
    [[ "$(jq 'length' <<<"$page_json")" -eq 0 ]] && break
    jq -c --slurpfile acc "$allfile" \
      "\$acc[0] + [ .[] | select(.draft | not) | $filter
        | {tag_name, published_at, assets: [.assets[] | {name, digest}]} ]" \
      <<<"$page_json" >"$allfile.new"
    mv "$allfile.new" "$allfile"
    [[ "$(jq 'length' "$allfile")" -ge 5 ]] && break
  done

  candidates=$(jq -c 'sort_by(.published_at) | reverse | .[]' "$allfile")
  rm -f "$allfile"

  if [[ -z "$candidates" ]]; then
    echo "error: no $chan releases found for $REPO" >&2
    return 1
  fi

  local candidate tag version missing
  while IFS= read -r candidate; do
    tag=$(jq -r '.tag_name' <<<"$candidate")
    version="${tag#v}"
    missing=$(missing_assets "$version" "$candidate")
    if [[ -n "$missing" ]]; then
      echo "skipping $tag: missing assets: $missing" >&2
      continue
    fi
    printf '%s\t%s\n' "$version" "$candidate"
    return 0
  done <<<"$candidates"

  echo "error: no $chan release has assets for all supported systems" >&2
  return 1
}

updated=()

for chan in "${channels[@]}"; do
  resolved=$(resolve_channel "$chan")
  version="${resolved%%$'\t'*}"
  release_json="${resolved#*$'\t'}"

  current=$(jq -r --arg c "$chan" '.channels[$c].version // ""' "$SOURCES")
  if [[ "$version" == "$current" ]]; then
    echo "$chan: already up to date: $version" >&2
    continue
  fi

  echo "$chan: updating $current -> $version" >&2

  tmp=$(mktemp)
  jq --arg c "$chan" --arg v "$version" \
    '.channels[$c].version = $v' "$SOURCES" >"$tmp"

  while IFS=$'\t' read -r sys name; do
    digest=$(jq -r --arg n "$name" \
      '.assets[] | select(.name == $n) | .digest' <<<"$release_json")
    if [[ -z "$digest" || "$digest" == "null" ]]; then
      echo "error: asset $name not found in release v$version" >&2
      exit 1
    fi
    sha="${digest#sha256:}"
    jq --arg c "$chan" --arg s "$sys" --arg n "$name" --arg h "$sha" \
      '.channels[$c].assets[$s] = {name: $n, sha256: $h}' "$tmp" >"$tmp.new"
    mv "$tmp.new" "$tmp"
  done < <(patterns "$version" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  mv "$tmp" "$SOURCES"
  updated+=("$chan $version")
done

for line in ${updated[@]+"${updated[@]}"}; do
  echo "$line"
done
