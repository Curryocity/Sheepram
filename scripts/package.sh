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

is_system_windows_dll() {
  case "$1" in
    KERNEL32.dll|USER32.dll|GDI32.dll|SHELL32.dll|OLE32.dll|COMDLG32.dll|ADVAPI32.dll|COMCTL32.dll|IMM32.dll|OLEAUT32.dll|WS2_32.dll|WINMM.dll|VERSION.dll|SHLWAPI.dll|UCRTBASE.dll|MSVCRT.dll|api-ms-win-*.dll)
      return 0
      ;;
  esac
  return 1
}

array_contains() {
  local needle="$1"
  shift
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

copy_windows_dlls() {
  local exe_path="$1"
  local out_dir="$2"
  local -a search_dirs=()
  local -a queue=()
  local -a seen_bins=()
  local -a missing=()
  local -a path_dirs=()

  if ! command -v objdump >/dev/null 2>&1; then
    echo "objdump not found; cannot bundle DLL dependencies." >&2
    return 1
  fi

  if command -v g++ >/dev/null 2>&1; then
    search_dirs+=("$(dirname "$(command -v g++)")")
  fi
  IFS=':' read -r -a path_dirs <<< "${PATH:-}"
  for d in "${path_dirs[@]}"; do
    [ -n "$d" ] && search_dirs+=("$d")
  done
  search_dirs+=("$(dirname "$exe_path")")

  queue+=("$exe_path")
  local idx=0
  while [ "$idx" -lt "${#queue[@]}" ]; do
    local bin="${queue[$idx]}"
    idx=$((idx + 1))
    array_contains "$bin" "${seen_bins[@]}" && continue
    seen_bins+=("$bin")

    while IFS= read -r dll; do
      [ -z "$dll" ] && continue
      if is_system_windows_dll "$dll"; then
        continue
      fi

      local staged="$out_dir/$dll"
      if [ -f "$staged" ]; then
        queue+=("$staged")
        continue
      fi

      local found=""
      local d=""
      for d in "${search_dirs[@]}"; do
        if [ -f "$d/$dll" ]; then
          found="$d/$dll"
          break
        fi
      done

      if [ -n "$found" ]; then
        cp -f "$found" "$staged"
        queue+=("$staged")
      elif ! array_contains "$dll" "${missing[@]}"; then
        missing+=("$dll")
      fi
    done < <(objdump -p "$bin" | awk '/DLL Name:/ {print $3}')
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing non-system DLL dependencies:" >&2
    local dll=""
    for dll in "${missing[@]}"; do
      echo "  - $dll" >&2
    done
    return 1
  fi
}

copy_linux_shared_libs() {
  local bin_path="$1"
  local lib_dir="$2"
  local mode="${LINUX_BUNDLE_MODE:-lean}"
  mkdir -p "$lib_dir"
  if ! command -v ldd >/dev/null 2>&1; then
    return
  fi

  echo "Linux library bundling mode: $mode"

  ldd "$bin_path" | awk '{if ($3 ~ /^\//) print $3}' | sort -u | while IFS= read -r so; do
    local so_name
    so_name="$(basename "$so")"

    case "$so" in
      /lib/*/ld-linux*.so*|/lib64/ld-linux*.so*|/lib/*/libc.so*|/lib64/libc.so*|/lib/*/libm.so*|/lib64/libm.so*|/lib/*/libpthread.so*|/lib64/libpthread.so*|/lib/*/libdl.so*|/lib64/libdl.so*|/lib/*/librt.so*|/lib64/librt.so*)
        continue
        ;;
    esac

    if [ "$mode" = "lean" ]; then
      case "$so_name" in
        libstdc++.so*|libgcc_s.so*|libglfw.so*|libglfw3.so*)
          ;;
        *)
          continue
          ;;
      esac
    fi

    cp -f "$so" "$lib_dir/"
  done
}

bundle_macos_glfw() {
  local app_bin="$1"
  local fw_dir="$2"

  if ! command -v otool >/dev/null 2>&1; then
    echo "otool not found; cannot bundle macOS dylibs." >&2
    return 1
  fi
  if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "install_name_tool not found; cannot rewrite macOS dylib paths." >&2
    return 1
  fi

  local glfw_src
  glfw_src="$(otool -L "$app_bin" | awk '/libglfw[.]3[.]dylib/ {print $1; exit}')"
  if [ -z "$glfw_src" ]; then
    return 0
  fi
  if [ ! -f "$glfw_src" ]; then
    echo "GLFW dylib referenced by app was not found on build host: $glfw_src" >&2
    return 1
  fi

  mkdir -p "$fw_dir"
  local glfw_dst="$fw_dir/libglfw.3.dylib"
  cp -f "$glfw_src" "$glfw_dst"
  chmod 755 "$glfw_dst"

  install_name_tool -id "@executable_path/../Frameworks/libglfw.3.dylib" "$glfw_dst"
  install_name_tool -change "$glfw_src" "@executable_path/../Frameworks/libglfw.3.dylib" "$app_bin"
}

case "$platform" in
  macos)
    stage_dir="$dist_dir/${app_name}-${version}-macos-${arch}"
    bundle_dir="$stage_dir/${app_name}.app"
    rm -rf "$stage_dir"
    mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources" "$bundle_dir/Contents/Frameworks"

    cp "$binary_path" "$bundle_dir/Contents/MacOS/$app_name"
    chmod +x "$bundle_dir/Contents/MacOS/$app_name"
    bundle_macos_glfw "$bundle_dir/Contents/MacOS/$app_name" "$bundle_dir/Contents/Frameworks"
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

    if command -v codesign >/dev/null 2>&1; then
      codesign --force --deep --sign - "$bundle_dir" >/dev/null
    fi

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

    cp "$binary_path" "$stage_dir/${app_name}.bin"
    chmod +x "$stage_dir/${app_name}.bin"
    copy_linux_shared_libs "$stage_dir/${app_name}.bin" "$stage_dir/lib"
    cat > "$stage_dir/$app_name" <<LAUNCH
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export LD_LIBRARY_PATH="\$ROOT_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$ROOT_DIR/${app_name}.bin" "\$@"
LAUNCH
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
    chmod +x "$stage_dir/${app_name}.desktop"
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
    copy_windows_dlls "$stage_dir/${app_name}.exe" "$stage_dir"
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
