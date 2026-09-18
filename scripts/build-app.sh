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
mkdir -p "$app_dir/Contents/Resources"
install -m 755 "$binary_dir/Scriber" "$app_dir/Contents/MacOS/Scriber"
install -m 644 App/Info.plist "$app_dir/Contents/Info.plist"
ditto "$binary_dir/Scriber_Scriber.bundle" "$app_dir/Contents/Resources/Scriber_Scriber.bundle"
ditto App/Resources "$app_dir/Contents/Resources"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

# Prefer the sole existing Apple Development identity so the app's identity
# remains stable across builds. Never create a certificate or alter trust.
# An explicit override wins; no/ambiguous development identity uses ad-hoc.
sign_identity="$(printenv SCRIBER_SIGN_IDENTITY || true)"
if [ -z "$sign_identity" ]; then
  development_identities="$(security find-identity -v -p codesigning 2>/dev/null |
    awk '/"Apple Development:/ {print $2}' || true)"
  case "$development_identities" in
    ""|*$'\n'*) sign_identity=- ;;
    *) sign_identity="$development_identities" ;;
  esac
fi
codesign --force --sign "$sign_identity" --timestamp=none "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
