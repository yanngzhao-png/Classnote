#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release --product Classnote
# Sign outside iCloud Desktop, where Finder metadata can be reattached during signing.
CLASSNOTE_STAGE=$(mktemp -d /private/tmp/classnote-build.XXXXXX)
trap 'rm -rf "$CLASSNOTE_STAGE"' EXIT
STAGED_APP="$CLASSNOTE_STAGE/Classnote.app"
APP_DEST="../Classnote.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp -X .build/release/Classnote "$STAGED_APP/Contents/MacOS/Classnote"
cp -X Info.plist "$STAGED_APP/Contents/Info.plist"
cp -X Assets/Classnote.icns "$STAGED_APP/Contents/Resources/Classnote.icns"
cp -X Assets/Classnote-Economics-Demo.pdf "$STAGED_APP/Contents/Resources/Classnote-Economics-Demo.pdf"
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ -d "$APP_DEST" ]]; then
  mkdir -p ".build/archived-app-bundles"
  mv "$APP_DEST" ".build/archived-app-bundles/Classnote-previous-$(date +%Y%m%d%H%M%S).backup"
fi
ditto --noextattr --norsrc "$STAGED_APP" "$APP_DEST"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" ../Classnote-macOS-arm64.zip
echo "Built: ${PWD:h}/Classnote.app"
