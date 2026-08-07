#!/bin/sh
# Build CoughButton.app — a self-contained menu-bar agent bundle.
#
# No Xcode project: compiles with Swift Package Manager (`swift build`) and
# assembles the result into a .app with an Info.plist so it runs as an
# LSUIElement (menu-bar-only) agent.
set -e

cd "$(dirname "$0")"

CONFIG=release
APP="CoughButton.app"
BIN_NAME="CoughButton"

# Signing is configurable via the environment (the Makefile's `release` target
# sets these).
#
# Local builds default to the Developer ID certificate when it is available,
# NOT to ad-hoc. This matters more than it looks: macOS binds an Accessibility
# (TCC) grant for an ad-hoc-signed app to that build's cdhash, so every rebuild
# looks like a brand-new app and silently loses the permission the user granted.
# Signing with a real identity keys the grant to Team ID + bundle ID, which
# survives rebuilds. Falls back to ad-hoc so the project still builds for anyone
# without the certificate.
DEVELOPER_ID_CERT="Developer ID Application: Victor Rodrigues (9N354A3UZK)"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEVELOPER_ID_CERT"; then
        SIGN_IDENTITY="$DEVELOPER_ID_CERT"
    else
        SIGN_IDENTITY="-"
    fi
fi
ENTITLEMENTS="${ENTITLEMENTS:-}"      # optional path to a .entitlements plist
HARDENED="${HARDENED:-}"              # non-empty → Hardened Runtime + secure timestamp
RELEASE_BUILD="${RELEASE_BUILD:-}"    # set by `make release`; gates the updater
VERSION="${VERSION:-$(cat VERSION 2>/dev/null)}"

echo "▸ Building ($CONFIG) …"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "✗ Build output not found at $BIN_PATH" >&2
    exit 1
fi

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Stamp the release version into the bundle (source Info.plist left untouched).
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"            "$APP/Contents/Info.plist"
fi

# Mark local builds explicitly. The updater used to infer "this is a dev build"
# from the absence of a Developer ID signature, but local builds are now signed
# with that same certificate (see above), so it needs to be told outright —
# otherwise a working-tree build would happily download a release over itself.
if [ -z "$RELEASE_BUILD" ]; then
    /usr/libexec/PlistBuddy -c "Add :CBDevBuild bool true" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CBDevBuild true" "$APP/Contents/Info.plist"
fi

# Icon: regenerate from source if it isn't there, then build the .icns.
if [ ! -f AppIcon.png ]; then
    echo "▸ Generating AppIcon.png from tools/icon-gen.swift …"
    swift tools/icon-gen.swift . app >/dev/null
fi
if [ -f AppIcon.png ]; then
    echo "▸ Generating app icon …"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"             AppIcon.png --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
        sips -z "$((size*2))" "$((size*2))" AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# Code-sign. Defaults to ad-hoc ("-") for local/dev builds; `make release`
# overrides SIGN_IDENTITY / ENTITLEMENTS / HARDENED for a Developer ID signature.
echo "▸ Signing ($SIGN_IDENTITY) …"
set -- --force --sign "$SIGN_IDENTITY"
[ -n "$HARDENED" ]     && set -- "$@" --options runtime --timestamp
[ -n "$ENTITLEMENTS" ] && set -- "$@" --entitlements "$ENTITLEMENTS"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign "$@" "$APP" 2>/dev/null || true
else
    codesign "$@" "$APP"
fi

echo "✓ Built $APP"
echo "  Launch with:  open $APP"
echo "  (Look for the mic + camera glyphs in your menu bar.)"
