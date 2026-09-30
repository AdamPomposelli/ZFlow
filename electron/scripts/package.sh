#!/bin/bash
# Assembles a self-contained "ZFlow UI.app" from the prebuilt Electron
# runtime in node_modules. No packaging tool needed: Electron ships a complete
# app bundle, and an app of our own is that bundle with our code dropped into
# Contents/Resources/app and the Info.plist renamed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

APP_NAME="${APP_NAME:-ZFlow UI}"
BUNDLE_ID="${BUNDLE_ID:-com.zippy.zflow.ui}"
OUT_DIR="${OUT_DIR:-$HERE/release}"
APP="$OUT_DIR/$APP_NAME.app"
ELECTRON_APP="$HERE/node_modules/electron/dist/Electron.app"

if [ ! -d "$ELECTRON_APP" ]; then
  echo "error: Electron runtime missing — run npm install in electron/ first" >&2
  exit 1
fi

npm run build

rm -rf "$APP"
mkdir -p "$OUT_DIR"
cp -R "$ELECTRON_APP" "$APP"

# Our code, and only what the app needs at runtime.
RES="$APP/Contents/Resources"
rm -rf "$RES/app" "$RES/default_app.asar"
mkdir -p "$RES/app"
cp -R dist dist-main package.json "$RES/app/"

# The speaker models need a native runtime, which cannot be bundled by esbuild.
mkdir -p "$RES/app/node_modules"
for native in sherpa-onnx-node sherpa-onnx-darwin-arm64 sherpa-onnx-darwin-x64; do
  [ -d "node_modules/$native" ] && cp -R "node_modules/$native" "$RES/app/node_modules/"
done

# Rename the bundle so the Dock and the menu bar say ZFlow, not Electron.
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$PLIST"

# One ZFlow in the Dock. Declared in the bundle rather than only asked for at
# runtime: app.dock.hide() is undone the moment macOS promotes the app back to
# the foreground, which the screen-capture APIs do.
plutil -replace LSUIElement -bool true "$PLIST"

# A URL scheme ZFlow can poke to bring this window forward.
#
# macOS will not let one app raise another's window on demand — cooperative
# activation refuses it — but it will always deliver a URL to the running
# instance, and an app may raise its own window. That is the only reliable
# way for the menu-bar app to say "come to the front".
plutil -replace CFBundleURLTypes -json '[{"CFBundleURLName":"ZFlow","CFBundleURLSchemes":["zflow"]}]' "$PLIST"

# macOS shows these when it asks for the permissions the notetaker needs.
plutil -replace NSMicrophoneUsageDescription -string "ZFlow records your side of a meeting so it can write down what was said." "$PLIST"
plutil -replace NSScreenCaptureUsageDescription -string "ZFlow records what your Mac plays so it can write down the other side of a meeting. No picture of your screen is kept." "$PLIST"
mv "$APP/Contents/MacOS/Electron" "$APP/Contents/MacOS/$APP_NAME"

# ZFlow's own icon, so the window and the app switcher do not show Electron's.
ICON_SOURCE="${ICON_SOURCE:-$HERE/../Resources/AppIcon.icns}"
if [ -f "$ICON_SOURCE" ]; then
  cp "$ICON_SOURCE" "$RES/electron.icns"
fi

# The helper bundles keep their own identifiers, which must stay distinct from
# and prefixed by ours or macOS refuses to launch them.
for helper in "$APP/Contents/Frameworks/"*.app; do
  [ -d "$helper" ] || continue
  suffix="$(basename "$helper" .app | tr ' ' '.' | tr '[:upper:]' '[:lower:]')"
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID.$suffix" "$helper/Contents/Info.plist"
done

# Signed with the same identity as the app proper when there is one, and
# ad-hoc otherwise.
#
# This matters more than it looks: an ad-hoc signature changes every time the
# bundle is rebuilt, and macOS keys Screen Recording and microphone access to
# that signature — so every rebuild silently revokes both, and the notetaker
# stops hearing anything until they are granted again. A stable identity, even
# a self-signed one, ends that.
IDENTITY="${CODESIGN_IDENTITY:-ZFlow Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null || true
  echo "signed $APP as $IDENTITY"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "signed $APP ad-hoc — permissions will need re-granting after each rebuild"
fi

echo "built $APP"
