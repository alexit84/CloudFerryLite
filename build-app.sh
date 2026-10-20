#!/bin/zsh
# Builds in release mode and creates dist/CloudFerryLite.app (icon, localizations, code signature).
set -euo pipefail
cd "$(dirname "$0")"

# Relative source paths and stripped debug symbols: the binary carries no absolute build paths.
SWIFT_FLAGS=(-c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/CloudFerryLite"

APP="dist/CloudFerryLite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CloudFerryLite"
strip -S -x "$APP/Contents/MacOS/CloudFerryLite"
# Localizations (English is the development language, Italian is translated).
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App icon rendered from an SF Symbol.
if swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then :; fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>it</string></array>
  <key>CFBundleExecutable</key><string>CloudFerryLite</string>
  <key>CFBundleIdentifier</key><string>io.github.alexit84.CloudFerryLite</string>
  <key>CFBundleName</key><string>CloudFerryLite</string>
  <key>CFBundleDisplayName</key><string>CloudFerryLite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# Sign with a stable identity (Apple Development / Developer ID) so the Keychain recognizes the app
# across builds. The identity comes from SIGN_IDENTITY, or from a local, untracked .signing-identity
# file (name or SHA-1 of the certificate). With exactly one certificate installed it is used directly;
# with several, the script refuses to guess. Without any certificate it signs ad-hoc.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then
  IDENTITY="$(head -1 .signing-identity | tr -d '\n')"
fi
if [[ -z "$IDENTITY" ]]; then
  CANDIDATES=("${(@f)$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "((Apple Development|Developer ID Application): [^"]+)".*/\1 \2/p')}")
  CANDIDATES=(${CANDIDATES:#})
  if (( ${#CANDIDATES} == 1 )); then
    IDENTITY="${CANDIDATES[1]%% *}"
  elif (( ${#CANDIDATES} > 1 )); then
    echo "Several signing certificates found; choose one with SIGN_IDENTITY or a .signing-identity file:" >&2
    printf '  %s\n' "${CANDIDATES[@]}" >&2
    exit 1
  fi
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
  echo "Signed with: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
  codesign --force --sign - "$APP"
  echo "No certificate found: ad-hoc signature (the Keychain will ask for access again after every build)"
fi
echo "Created $APP"
