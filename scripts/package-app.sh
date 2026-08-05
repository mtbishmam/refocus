#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

swift build -c release --product ReFocus

app_dir="$project_dir/.build/release/ReFocus.app"
legacy_app_dir="$project_dir/.build/release/Refocus.app"
binary="$project_dir/.build/release/ReFocus"
icon_source="$project_dir/Support/Assets/ReFocus-AppIcon.png"
iconset_dir="$project_dir/.build/release/ReFocus.iconset"
icon_file="$project_dir/.build/release/ReFocus.icns"

if [ -d "$app_dir" ]; then
    /bin/rm -rf "$app_dir"
fi

if [ -d "$legacy_app_dir" ]; then
    /bin/rm -rf "$legacy_app_dir"
fi

/bin/mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/bin/cp "$binary" "$app_dir/Contents/MacOS/ReFocus"
/bin/cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"

if [ -d "$iconset_dir" ]; then
    /bin/rm -rf "$iconset_dir"
fi
/bin/mkdir -p "$iconset_dir"
/usr/bin/sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$iconset_dir" -o "$icon_file"
/bin/cp "$icon_file" "$app_dir/Contents/Resources/ReFocus.icns"

/usr/bin/codesign --force --deep --sign - \
    --entitlements "$project_dir/Support/Refocus.entitlements" \
    "$app_dir"

/usr/bin/codesign --verify --deep --strict "$app_dir"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"

echo "$app_dir"
