#!/bin/sh
set -eu

# Universal (arm64 + x86_64) by default so the .app runs on both Apple Silicon
# and Intel Macs. Override: ARCHS="arm64" Scripts/build_app.sh
ARCHS="${ARCHS:-arm64 x86_64}"
# Signing identity: "-" = ad-hoc (default; opens on other Macs after the user
# clears quarantine). Set SIGN_IDENTITY to a "Developer ID Application: …" to
# produce a notarization-ready, hardened-runtime build.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Build each arch separately (single-arch builds use llbuild and work under
# Command Line Tools; the `swift build --arch a --arch b` multi-arch path needs
# full Xcode's xcbuild). Then lipo the per-arch binaries into one universal Mach-O.
BINARIES=""
BUNDLE_SRC=""
for arch in $ARCHS; do
  swift build -c release --arch "$arch"
  arch_dir=".build/${arch}-apple-macosx/release"
  BINARIES="$BINARIES $arch_dir/Trinity"
  if [ -d "$arch_dir/Trinity_Trinity.bundle" ]; then
    BUNDLE_SRC="$arch_dir/Trinity_Trinity.bundle"
  fi
done

APP_DIR=".build/release/Trinity.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICON_SRC="Sources/Trinity/Resources/AppIcon.png"
ICONSET=".build/release/Trinity.iconset"
ICON_FILE="$RESOURCES_DIR/TrinityIcon.icns"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
# lipo -create with a single input just copies it, so this handles 1+ archs.
# shellcheck disable=SC2086
lipo -create $BINARIES -output "$MACOS_DIR/Trinity"

if [ -n "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$RESOURCES_DIR/"
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ICON_FILE"
rm -rf "$ICONSET"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Trinity</string>
  <key>CFBundleIdentifier</key>
  <string>dev.trinity.orchestrator</string>
  <key>CFBundleName</key>
  <string>Trinity</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>TrinityIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Sign. Ad-hoc by default; hardened runtime only for a real Developer ID (needed
# for notarization). Sign nested bundles first, the app last.
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP_DIR"
  echo "ad-hoc signed (set SIGN_IDENTITY for a notarizable build)"
else
  find "$APP_DIR/Contents/Resources" -name '*.bundle' -maxdepth 1 -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" {}
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
  echo "signed with: $SIGN_IDENTITY"
fi

codesign --verify --deep --strict "$APP_DIR" && echo "codesign verify: ok"
echo "$APP_DIR"
