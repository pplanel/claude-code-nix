#!/usr/bin/env bash
# Pin manifest.json to Anthropic's current stable release (or latest with
# --latest). Keeps only the macOS and glibc Linux platforms we can build for.
# usage: update.sh [--latest] [--dry-run]
set -euo pipefail

base=https://downloads.claude.ai/claude-code-releases
channel=stable dry=0
for arg in "$@"; do
  case $arg in
    --latest) channel=latest ;;
    --dry-run) dry=1 ;;
    *) echo "usage: $0 [--latest] [--dry-run]" >&2; exit 2 ;;
  esac
done

out="$(dirname "$0")/manifest.json"
version=$(curl -fsSL "$base/$channel")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "unexpected $channel answer: $version" >&2; exit 1; }
current=$(jq -r .version "$out" 2>/dev/null || echo none)
echo "$channel: $version (pinned: $current)"
[ "$dry" = 0 ] || exit 0
[ "$version" != "$current" ] || exit 0

curl -fsSL "$base/$version/manifest.json" |
  jq '{version, platforms: (.platforms | with_entries(select(.key | test("^(darwin|linux)-(arm64|x64)$"))) | map_values({binary, checksum, size}))}' >"$out.tmp"
mv "$out.tmp" "$out"
echo "wrote $out"
