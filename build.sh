#!/bin/zsh
# Builds build/Burrow.app, signed with the Apple Development identity (a stable signature keeps the
# Desktop/Documents/Downloads grants across rebuilds). --install puts it in /Applications and relaunches it.
# --release ignores config.local.env and signs with Developer ID (hardened runtime + secure timestamp) for
# notarization: see ../Kit/tools/release-app.sh.
set -euo pipefail
cd "$(dirname "$0")"

# Optional, gitignored: BUNDLE_ID, SIGN_IDENTITY and PREVIOUS_BUNDLE_ID (settings are copied once from it), see config.example.env.
BUNDLE_ID=app.newitools.Burrow
SIGN_IDENTITY=""
PREVIOUS_BUNDLE_ID=""
RELEASE=0; [[ "${1:-}" == "--release" ]] && RELEASE=1
# A public release never reads the local file: no previous id or personal settings in the shipped app.
[ "$RELEASE" = 0 ] && [ -f config.local.env ] && source ./config.local.env

swift build -c release
APP=build/Burrow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Burrow "$APP/Contents/MacOS/Burrow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
[ -z "$PREVIOUS_BUNDLE_ID" ] || /usr/libexec/PlistBuddy -c "Add :BurrowPreviousBundleID string $PREVIOUS_BUNDLE_ID" "$APP/Contents/Info.plist"
[ -f Resources/Burrow.icns ] || .build/release/Burrow --make-icon Resources/Burrow.icns   # drawn by the app itself (IconArt)
cp Resources/Burrow.icns "$APP/Contents/Resources/Burrow.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The app-wide accent (violet, not the system blue): selection, sidebar symbols, buttons.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --output-partial-info-plist build/assets-info.plist >/dev/null

# Sparkle (updates): embedded and its helpers signed inside-out before the app, see Kit's docs/updates.md.
KIT=../Kit; [ -d "$KIT" ] || KIT=.build/checkouts/mac-tools-kit
IDENTITY=${SIGN_IDENTITY:-}
if [ "$RELEASE" = 1 ]; then
  [ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
  [ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain" >&2; exit 1; }
  echo "==> Signing for release with $IDENTITY"
  "$KIT/tools/embed-sparkle.sh" "$APP" "$IDENTITY" --release
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Built $APP (release)"; exit 0
fi
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
"$KIT/tools/embed-sparkle.sh" "$APP" "${IDENTITY:--}"
codesign --force --sign "${IDENTITY:--}" "$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Burrow 2>/dev/null || true
  while pgrep -x Burrow >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Burrow.app
  cp -R "$APP" /Applications/Burrow.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Burrow.app
  open /Applications/Burrow.app
  echo "Installed and launched /Applications/Burrow.app"
else
  echo "Built $APP"
fi
