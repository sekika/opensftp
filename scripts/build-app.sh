#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS 13以降とXcode Command Line Toolsが必要です。' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
commit=''
commit_date=''
repository=''
dirty=false
if git cat-file -e HEAD:./scripts/build-app.sh 2>/dev/null &&
   commit_info="$(git show -s --format='%H %cI' HEAD)"; then
  read -r commit commit_date <<< "$commit_info"
  remote="$(git config --get "branch.$(git branch --show-current).remote" || true)"
  if [[ -n "$remote" && "$remote" != . ]]; then
    repository="$(git remote get-url "$remote" 2>/dev/null || true)"
  fi
  if [[ -z "$repository" ]]; then
    repository="$(git remote get-url origin 2>/dev/null || true)"
  fi
  # Avoid embedding URL credentials, query parameters, or fragments.
  if [[ "$repository" =~ ^([[:alpha:]][[:alnum:]+.-]*://)([^/]*@)(.*)$ ]]; then
    repository="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
  fi
  repository="${repository%%[?#]*}"
  if [[ -n "$(git status --porcelain --untracked-files=normal -- .)" ]]; then
    dirty=true
  fi
fi
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swift build -c "$configuration" --arch arm64 --arch x86_64
  binary_dir="$(swift build -c "$configuration" --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c "$configuration"
  binary_dir="$(swift build -c "$configuration" --show-bin-path)"
fi
app="$HOME/Applications/OpenSFTP.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/OpenSFTP" "$app/Contents/MacOS/OpenSFTP"
cp scripts/Info.plist "$app/Contents/Info.plist"
if [[ -n "$commit" && -n "$commit_date" ]]; then
  /usr/bin/plutil -insert OpenSFTPBuildCommit -string "$commit" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert OpenSFTPBuildCommitDate -string "$commit_date" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert OpenSFTPBuildDirty -bool "$dirty" "$app/Contents/Info.plist"
fi
if [[ -n "$repository" ]]; then
  /usr/bin/plutil -insert OpenSFTPBuildRepository -string "$repository" "$app/Contents/Info.plist"
fi
cp Sources/OpenSFTP/Resources/AppIcon.png "$app/Contents/Resources/AppIcon.png"
iconset='build/AppIcon.iconset'
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" Sources/OpenSFTP/Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" Sources/OpenSFTP/Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "作成しました: $app"
