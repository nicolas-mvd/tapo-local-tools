#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
destination=${1:-"$HOME/Applications/Tapo Menu.app"}
[[ $destination = /* && $destination = *.app ]] || {
    printf '%s\n' 'Usage: bash macos/build.sh [/absolute/path/Tapo Menu.app]' >&2
    exit 1
}
node=${TAPO_NODE:-$(command -v node || true)}
ffmpeg=${TAPO_FFMPEG:-$(command -v ffmpeg || true)}
[[ -n $node && -x $node ]] || { printf '%s\n' 'Install Node.js 22 or 24 first.' >&2; exit 1; }
[[ -n $ffmpeg && -x $ffmpeg ]] || { printf '%s\n' 'Install FFmpeg or set TAPO_FFMPEG.' >&2; exit 1; }
node_major=$("$node" -p 'process.versions.node.split(".")[0]')
[[ $node_major == 22 || $node_major == 24 ]] || { printf '%s\n' 'Use Node.js 22 or 24.' >&2; exit 1; }
export PATH="${node%/*}:$PATH"
command -v npm >/dev/null || { printf '%s\n' 'npm is required to build Tapo Menu.' >&2; exit 1; }

if [[ -e $destination || -L $destination ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)
    [[ ! -L $destination && $identifier == local.tapomenu.macos ]] || {
        printf '%s\n' 'The destination is already used by another app.' >&2
        exit 1
    }
fi

mkdir -p -- "${destination%/*}"
staging=$(mktemp -d "${destination%/*}/.tapo-menu-build.XXXXXXXX")
trap '/usr/bin/python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$staging"' EXIT
app="$staging/Tapo Menu.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/"{macos,src,scripts}
cp "$repo/macos/Info.plist" "$app/Contents/Info.plist"
/usr/bin/plutil -insert TapoNodeExecutable -string "$node" "$app/Contents/Info.plist"
cp "$repo/macos/bridge.cjs" "$repo/macos/camera_status.py" "$repo/macos/Sign in to Tapo.command" "$resources/macos/"
cp "$repo/src/media.cjs" "$resources/src/"
cp "$repo/scripts/tapo-login.py" "$repo/scripts/install-credentials.py" "$resources/scripts/"
cp "$repo/watch_detection.py" "$repo/package.json" "$repo/package-lock.json" "$resources/"
cp "$repo/LICENSE" "$repo/THIRD-PARTY-NOTICES" "$resources/"
cp "$ffmpeg" "$resources/ffmpeg"
chmod 755 "$resources/ffmpeg" "$resources/macos/Sign in to Tapo.command"
"$resources/ffmpeg" -version >/dev/null
npm ci --ignore-scripts --prefix "$resources"

/usr/bin/swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit "$repo/macos/App.swift" "$repo/macos/TapoBridge.swift" \
    "$repo/macos/LiveWindow.swift" -o "$app/Contents/MacOS/TapoMenu"
/usr/bin/codesign --force --deep --sign - "$app"

if [[ -e $destination ]]; then
    mv "$destination" "$staging/previous.app"
    if ! mv "$app" "$destination"; then
        mv "$staging/previous.app" "$destination"
        exit 1
    fi
else
    mv "$app" "$destination"
fi
printf 'Built %s\n' "$destination"
