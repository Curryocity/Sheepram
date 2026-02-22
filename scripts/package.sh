#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <platform> <arch> <binary-path>" >&2
  exit 1
fi

platform="$1"
arch="$2"
binary_path="$3"
version="${VERSION:-dev}"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
asset_dir="$root_dir/asset"
presets_dir="$root_dir/presets"
dist_dir="$root_dir/dist"
app_name="Sheepram"
mac_icon_icns="$asset_dir/icon/app.icns"

if [ ! -f "$binary_path" ]; then
  echo "Binary not found: $binary_path" >&2
  exit 1
fi
if [ ! -d "$asset_dir" ]; then
  echo "Asset directory not found: $asset_dir" >&2
  exit 1
fi

mkdir -p "$dist_dir"

case "$platform" in
  macos)
    stage_dir="$dist_dir/${app_name}-${version}-macos-${arch}"
    bundle_dir="$stage_dir/${app_name}.app"
    rm -rf "$stage_dir"
    mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"

    cp "$binary_path" "$bundle_dir/Contents/MacOS/$app_name"
    chmod +x "$bundle_dir/Contents/MacOS/$app_name"
    cp -R "$asset_dir" "$bundle_dir/Contents/Resources/"
    if [ -f "$mac_icon_icns" ]; then
      cp "$mac_icon_icns" "$bundle_dir/Contents/Resources/app.icns"
    fi
    if [ -d "$presets_dir" ]; then
      cp -R "$presets_dir" "$bundle_dir/Contents/Resources/"
    fi
    find "$bundle_dir/Contents/Resources/asset" -name '.DS_Store' -delete
    if [ -d "$bundle_dir/Contents/Resources/presets" ]; then
      find "$bundle_dir/Contents/Resources/presets" -name '.DS_Store' -delete
    fi

    icon_plist=""
    if [ -f "$mac_icon_icns" ]; then
      icon_plist=$'  <key>CFBundleIconFile</key>\n  <string>app.icns</string>'
    fi

    cat > "$bundle_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${app_name}</string>
  <key>CFBundleIdentifier</key>
  <string>com.sheepram.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
${icon_plist}
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

    (
      cd "$dist_dir"
      zip -qr "${app_name}-${version}-macos-${arch}.zip" "${app_name}-${version}-macos-${arch}"
    )
    echo "Created $dist_dir/${app_name}-${version}-macos-${arch}.zip"
    ;;

  linux)
    stage_dir="$dist_dir/${app_name}-${version}-linux-${arch}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    cp "$binary_path" "$stage_dir/$app_name"
    chmod +x "$stage_dir/$app_name"
    cp -R "$asset_dir" "$stage_dir/"
    if [ -d "$presets_dir" ]; then
      cp -R "$presets_dir" "$stage_dir/"
    fi
    cat > "$stage_dir/${app_name}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=${app_name}
Exec=./${app_name}
Icon=asset/icon/app
Terminal=false
Categories=Utility;
DESKTOP
    find "$stage_dir/asset" -name '.DS_Store' -delete
    if [ -d "$stage_dir/presets" ]; then
      find "$stage_dir/presets" -name '.DS_Store' -delete
    fi

    tar -C "$dist_dir" -czf "$dist_dir/${app_name}-${version}-linux-${arch}.tar.gz" "${app_name}-${version}-linux-${arch}"
    echo "Created $dist_dir/${app_name}-${version}-linux-${arch}.tar.gz"
    ;;

  windows)
    stage_dir="$dist_dir/${app_name}-${version}-windows-${arch}"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    cp "$binary_path" "$stage_dir/${app_name}.exe"
    cp -R "$asset_dir" "$stage_dir/"
    if [ -d "$presets_dir" ]; then
      cp -R "$presets_dir" "$stage_dir/"
    fi
    find "$stage_dir/asset" -name '.DS_Store' -delete
    if [ -d "$stage_dir/presets" ]; then
      find "$stage_dir/presets" -name '.DS_Store' -delete
    fi

    (
      cd "$dist_dir"
      zip -qr "${app_name}-${version}-windows-${arch}.zip" "${app_name}-${version}-windows-${arch}"
    )
    echo "Created $dist_dir/${app_name}-${version}-windows-${arch}.zip"
    ;;

  *)
    echo "Unsupported platform: $platform" >&2
    exit 1
    ;;
esac
