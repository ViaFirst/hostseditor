#!/bin/bash
# Build HostsEditor.app.   ./build.sh          -> build/HostsEditor.app
#                      ./build.sh install  -> also copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HostsEditor"
BUNDLE_ID="com.viafirst.hostseditor"
APP="build/$APP_NAME.app"

./scripts/check-strings.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

# A real identity when available (APP_SIGN_IDENTITY), otherwise ad-hoc. The designated requirement
# is pinned to the bundle id so Screen Recording / Accessibility grants survive rebuilds.
IDENTITY="${APP_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
  # Remove every older copy (found by bundle id via Spotlight and LaunchServices), so Finder, Spotlight and
  # "Open With" only ever see the new build. The fresh build in build/ is the one being installed.
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  OLD_COPIES="$( { mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null
                   "$LSREGISTER" -dump 2>/dev/null | sed -n "s|^path: *\(.*/$APP_NAME\.app\) (0x[0-9a-f]*)\$|\1|p"
                   echo "$HOME/Applications/$APP_NAME.app"; echo "/Applications/$APP_NAME.app"; } | sort -u )"
  NEW_ABS="$(cd "$(dirname "$APP")" && pwd)/$APP_NAME.app"
  while IFS= read -r old; do
    [ -n "$old" ] && [ "$old" != "$NEW_ABS" ] || continue
    if [ -d "$old" ] && [ "$(defaults read "$old/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BUNDLE_ID" ]; then
      echo "Removing old copy: $old"
      rm -rf "$old"
    fi
    "$LSREGISTER" -u "$old" 2>/dev/null || true
  done <<< "$OLD_COPIES"
  mkdir -p "$HOME/Applications"
  # Move, not copy: a second .app left in build/ shows up in Spotlight and "Open With".
  mv "$APP" "$HOME/Applications/"
  "$LSREGISTER" -f "$HOME/Applications/$APP_NAME.app" 2>/dev/null || true
  open "$HOME/Applications/$APP_NAME.app"
  echo "Installed $(defaults read "$HOME/Applications/$APP_NAME.app/Contents/Info" CFBundleShortVersionString) to ~/Applications/$APP_NAME.app"
fi
