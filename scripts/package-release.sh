#!/bin/bash
# Package a committed source snapshot without replacing build/Scriber.app.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [new-output-directory]" >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "Release packaging requires an Apple Silicon Mac with Xcode 26+." >&2
  exit 1
fi
source_paths=(App Sources Tests Package.swift scripts/build-app.sh)
if [ -n "$(git status --porcelain --untracked-files=all -- "${source_paths[@]}")" ]; then
  echo "Commit app source and build changes before packaging a release." >&2
  exit 1
fi
source_commit="$(git rev-parse HEAD)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/scriber-release.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/source"
git archive "$source_commit" "${source_paths[@]}" | tar -xf - -C "$work_dir/source"
plist="$work_dir/source/App/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a three-part numeric app version, got: $version" >&2
  exit 1
fi
output_dir="${1:-$project_dir/build/releases/$version}"
if [[ "$output_dir" != /* ]]; then output_dir="$project_dir/$output_dir"; fi
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
  echo "Output already exists; choose a new directory: $output_dir" >&2
  exit 1
fi

# Public previews are deliberately ad-hoc signed, not signed with whichever
# personal/work development certificate happens to be installed on this Mac.
SCRIBER_SIGN_IDENTITY=- "$work_dir/source/scripts/build-app.sh" release
app="$work_dir/source/build/Scriber.app"
test "$(lipo -archs "$app/Contents/MacOS/Scriber")" = arm64
codesign --verify --strict "$app"
codesign --display --verbose=2 "$app" 2> "$work_dir/signature.txt"
if ! rg -q '^Signature=adhoc$' "$work_dir/signature.txt"; then
  echo "Expected an ad-hoc signature for the preview package." >&2
  exit 1
fi

mkdir "$work_dir/assets" "$work_dir/disk"
base="Scriber-$version-macOS-arm64"
ditto -c -k --keepParent --norsrc "$app" "$work_dir/assets/$base.zip"
ditto "$app" "$work_dir/disk/Scriber.app"
ln -s /Applications "$work_dir/disk/Applications"
cat > "$work_dir/disk/Install.txt" <<'EOF'
Scriber for macOS / 安装说明

Requires Apple Silicon (M1 or later) and macOS 26 or later.
Drag Scriber.app into Applications, then open it there.
Scriber lives in the menu bar. Click its waveform icon or press Option-R.
Allow Screen & System Audio Recording and Microphone when requested.

This preview is not notarized by Apple. If macOS blocks the first launch,
open System Settings > Privacy & Security, then choose Open Anyway for
Scriber and confirm. Only approve a download you trust from this repository.
Do not disable Gatekeeper. No terminal commands or Xcode are needed to use it.

需要 Apple Silicon（M1 或更新芯片）和 macOS 26 或更新版本。
将 Scriber.app 拖进 Applications（应用程序），然后从那里打开。
Scriber 常驻菜单栏。点击波形图标，或按 Option-R 呼出面板。
按系统提示授予屏幕与系统音频录制、麦克风权限。

此预览版尚未经过 Apple 公证。首次打开若被系统拦截，请前往
系统设置 > 隐私与安全性，为 Scriber 点击「仍要打开」并确认。
只对从本仓库下载且你信任的应用这样操作；无需关闭 Gatekeeper。
使用应用无需终端命令，也无需安装 Xcode。

https://github.com/luyao618/dayscribe/releases
EOF
hdiutil create -volname "Scriber $version" -srcfolder "$work_dir/disk" \
  -format UDZO "$work_dir/assets/$base.dmg"
hdiutil verify "$work_dir/assets/$base.dmg"
cat > "$work_dir/assets/BUILD.txt" <<EOF
Scriber $version (build $build_number)
Source: https://github.com/luyao618/dayscribe/commit/$source_commit
Architecture: arm64 (Apple Silicon)
Minimum macOS: $minimum_os
Signature: ad-hoc
Apple notarization: none
EOF
xcodebuild -version >> "$work_dir/assets/BUILD.txt"
(
  cd "$work_dir/assets"
  shasum -a 256 "$base.dmg" "$base.zip" BUILD.txt > SHA256SUMS
)
# A new directory prevents accidental replacement of an earlier release.
mkdir -p "$(dirname "$output_dir")"
mkdir "$output_dir"
ditto "$work_dir/assets" "$output_dir"
printf 'Release assets: %s\n' "$output_dir"
