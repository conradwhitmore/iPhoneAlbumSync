#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/iphone-sync-package.XXXXXXXX")
trap 'rm -rf "$build_dir"' EXIT

arch=$(uname -m)
app="$build_dir/iPhone 相册同步.app"
IPHONE_SYNC_APP_PATH="$app" bash "$source_dir/build.sh" --portable
/usr/bin/codesign --verify --deep --strict "$app"

version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
output="${1:-$(dirname "$source_dir")/iPhone 相册同步-$version-$arch.pkg}"
requirements="$build_dir/requirements.plist"
cat > "$requirements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>arch</key><array><string>$arch</string></array>
<key>os</key><array><string>14.0</string></array>
</dict></plist>
PLIST
build_args=(--product "$requirements" --component "$app" /Applications)
if [[ -n "${IPHONE_SYNC_INSTALLER_IDENTITY:-}" ]]; then
    build_args=(--sign "$IPHONE_SYNC_INSTALLER_IDENTITY" "${build_args[@]}")
fi
/usr/bin/productbuild "${build_args[@]}" "$output"
printf '%s\n' "$output"
