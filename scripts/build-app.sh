#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration=debug
if [ "$#" -gt 0 ]; then configuration="$1"; fi
case "$configuration" in
  debug|release) ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

cd "$project_dir"
if pgrep -x Scriber >/dev/null; then
  echo "Quit Scriber before rebuilding its running app bundle." >&2
  exit 1
fi
swift build --configuration "$configuration"
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app_dir="$project_dir/build/Scriber.app"
mkdir -p "$app_dir/Contents/MacOS"
install -m 755 "$binary_dir/Scriber" "$app_dir/Contents/MacOS/Scriber"
install -m 644 App/Info.plist "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

# Ad-hoc signing supports this local-use app without a paid developer account.
# Set SCRIBER_SIGN_IDENTITY to use an existing local code-signing identity.
sign_identity="$(printenv SCRIBER_SIGN_IDENTITY || true)"
if [ -z "$sign_identity" ]; then sign_identity=-; fi
codesign --force --sign "$sign_identity" --timestamp=none "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
