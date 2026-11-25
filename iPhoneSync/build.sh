#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
local_settings="$source_dir/../build.local.env"
if [[ -f "$local_settings" ]]; then
    source "$local_settings"
fi
bundle_id="${IPHONE_SYNC_BUNDLE_ID:-local.iphonealbumsync.app}"
if [[ ! "$bundle_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    printf '%s\n' 'IPHONE_SYNC_BUNDLE_ID 不是有效的应用标识。' >&2
    exit 1
fi
app="${IPHONE_SYNC_APP_PATH:-$(dirname "$source_dir")/iPhone 相册同步.app}"
contents="$app/Contents"
runtime="$HOME/Library/Application Support/iPhoneAlbumSync/runtime-v1"
dependencies=('apsw==3.54.1.0' 'pymobiledevice3==11.63.1' 'makelive==0.7.0')
signing_identity="${IPHONE_SYNC_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    development_identities=$(/usr/bin/security find-identity -v -p codesigning |
        awk '/"Apple Development: / { print $2 }')
    if [[ -n "$development_identities" && "$development_identities" != *$'\n'* ]]; then
        signing_identity="$development_identities"
    else
        signing_identity=-
        printf '%s\n' '未找到唯一的 Apple Development 签名身份。使用临时签名，可通过 IPHONE_SYNC_SIGN_IDENTITY 指定证书。' >&2
    fi
fi
mkdir -p "$contents/MacOS" "$contents/Resources"
if [[ "${1:-}" == --portable ]]; then
    python_version=3.12.16
    runtime="$contents/Resources/Python"
    if [[ -e "$runtime" ]]; then
        printf '%s\n' '便携构建需要一个新的输出路径，请设置 IPHONE_SYNC_APP_PATH。' >&2
        exit 1
    fi
    uv python install "$python_version"
    managed_python=$(uv python find --no-project --managed-python --resolve-links "$python_version")
    python_prefix=$("$managed_python" -I -c 'import sys; print(sys.base_prefix)')
    /usr/bin/ditto "$python_prefix" "$runtime"
    uv pip install --python "$runtime/bin/python3" \
        --target "$runtime/lib/python3.12/site-packages" --link-mode copy "${dependencies[@]}"
    while IFS= read -r -d '' binary; do
        /usr/bin/codesign --force --sign "$signing_identity" "$binary"
    done < <(find "$runtime" -type f \( -name '*.so' -o -name '*.dylib' -o -name python3.12 \) -print0)
else
    if [[ ! -x "$runtime/bin/python3" ]]; then
        mkdir -p "$(dirname "$runtime")"
        uv venv --python 3.12 "$runtime"
    fi
    if ! "$runtime/bin/python3" -c 'from importlib.metadata import version; assert [version(n) for n in ("apsw", "pymobiledevice3", "makelive")] == ["3.54.1.0", "11.63.1", "0.7.0"]' 2>/dev/null; then
        uv pip install --python "$runtime/bin/python3" "${dependencies[@]}"
    fi
fi
icon_work=$(mktemp -d "${TMPDIR:-/tmp}/iphone-sync-icon.XXXXXXXX")
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$source_dir/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" "$source_dir/AppIcon.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
xcrun clang -fobjc-arc -arch "$(uname -m)" -mmacosx-version-min=14.0 -c "$source_dir/PhotoKitImporter.m" -o "$icon_work/PhotoKitImporter.o"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -O \
    -import-objc-header "$source_dir/PhotoKitImporter.h" "$source_dir/App.swift" "$source_dir/DeviceListener.swift" "$icon_work/PhotoKitImporter.o" \
    -framework Photos -o "$contents/MacOS/iPhoneAlbumSync"
cp "$source_dir/sync_backend.py" "$source_dir/phone_catalog.py" "$contents/Resources/"
rm -f "$contents/Resources/import_test_photos.py"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>iPhoneAlbumSync</string>
<key>CFBundleIdentifier</key><string>local.iphonealbumsync.app</string>
<key>CFBundleDisplayName</key><string>iPhone 相册同步</string>
<key>CFBundleName</key><string>iPhone 相册同步</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.2.9</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPhotoLibraryAddUsageDescription</key><string>在后台将 iPhone 上的照片和视频追加到你选定的 Apple 照片图库。</string>
<key>NSLocalNetworkUsageDescription</key><string>查找并读取已与此 Mac 配对的 iPhone。</string>
<key>NSRemovableVolumesUsageDescription</key><string>访问你选定的外置硬盘上的苹果照片图库。</string>
</dict></plist>
PLIST
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$contents/Info.plist"
/usr/bin/codesign --force --sign "$signing_identity" "$app"
printf '%s\n' "$app"
