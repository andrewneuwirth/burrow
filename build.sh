#!/bin/zsh
# Builds build/Burrow.app, signed with the Apple Development identity (a stable signature keeps the
# Desktop/Documents/Downloads grants across rebuilds). --install puts it in /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Burrow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Burrow "$APP/Contents/MacOS/Burrow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Burrow.icns ] || .build/release/Burrow --make-icon Resources/Burrow.icns   # drawn by the app itself (IconArt)
cp Resources/Burrow.icns "$APP/Contents/Resources/Burrow.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The app-wide accent (violet, not the system blue): selection, sidebar symbols, buttons.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --output-partial-info-plist build/assets-info.plist >/dev/null

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
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
