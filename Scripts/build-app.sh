#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MacCleaner
app=build/macCleaner.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/icon
swift Scripts/make-icon.swift build/icon/AppIcon.iconset
iconutil -c icns build/icon/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/MacCleaner" "$app/Contents/MacOS/MacCleaner"
cat > "$app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>MacCleaner</string>
<key>CFBundleIdentifier</key><string>local.maccleaner.app</string>
<key>CFBundleName</key><string>macCleaner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
if [[ -f Config/OAuthClients.json ]]; then
  cp Config/OAuthClients.json "$app/Contents/Resources/OAuthClients.json"
fi
# SIGN_IDENTITY : « Developer ID Application: … ». Sans lui, signature locale seulement.
# NOTARY_PROFILE : profil créé avec `xcrun notarytool store-credentials`.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE exige SIGN_IDENTITY" >&2; exit 1; }
  ditto -c -k --keepParent "$app" build/macCleaner.zip
  xcrun notarytool submit build/macCleaner.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
fi
echo "$app"
