#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
app="$HOME/Applications/HDB630Control.app"
build_dir="${TMPDIR:-/tmp}/hdb630-local-build"
built="$build_dir/Build/Products/Release/HDB630Control.app"
build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT

echo "Building HDB 630 Control…"
if ! xcodebuild -quiet -project "$repo/HDB630Control.xcodeproj" -scheme HDB630Control \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO build >"$build_log" 2>&1; then
  tail -80 "$build_log" >&2
  exit 1
fi
codesign --force --deep --sign - "$built" >/dev/null 2>&1
codesign --verify --deep "$built"

mkdir -p "$(dirname "$app")"
running=$(pgrep -f "^${app}/Contents/MacOS/HDB630Control$" || true)
if [[ -n "$running" ]]; then
  kill -TERM $running
  for _ in {1..20}; do
    [[ -z "$(pgrep -f "^${app}/Contents/MacOS/HDB630Control$" || true)" ]] && break
    sleep 0.25
  done
  if [[ -n "$(pgrep -f "^${app}/Contents/MacOS/HDB630Control$" || true)" ]]; then
    echo "The installed app is still running; quit it and rerun this script." >&2
    exit 1
  fi
fi

staged="$HOME/Applications/.HDB630Control-new.app"
rm -rf "$staged"
ditto "$built" "$staged"
rm -rf "$app"
mv "$staged" "$app"
open "$app"
echo "Installed and launched $app"
