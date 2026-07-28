#!/bin/zsh -f
# =============================================================================
#  build.sh — command-line build of QLCodePreview, no Xcode required.
#
#  Produces:
#    build/QLCodePreview.app                                    (host app)
#      Contents/PlugIns/QLCodePreviewExtension.appex               (Quick Look
#                                                                  preview extension)
#
#  Why a host app at all? Since macOS 12, Quick Look *preview* extensions
#  (QLPreviewingController, extension point com.apple.quicklook.preview) are
#  ordinary App Extensions. Unlike the legacy .qlgenerator plug-ins, PlugInKit
#  will not discover a loose .appex sitting in ~/Library/QuickLook — the
#  extension must be embedded in a container .app's Contents/PlugIns.
#  QLCodePreviewApp/ is that minimal container app.
#
#  Getting it *registered* turns out to need one more explicit step beyond
#  just launching the app: `install` below force-registers the installed
#  .app with LaunchServices (`lsregister -f`) before calling `pluginkit -a`
#  on the embedded .appex. Skipping the lsregister step is why `pluginkit -a`
#  can silently do nothing even for a correctly built and signed extension —
#  `open`ing the app alone isn't sufficient for LaunchServices to notice a
#  *new* app extension reliably.
#
#  Even after that, macOS requires a one-time manual step no script can do:
#  System Settings → General → Login Items & Extensions → Quick Look →
#  toggle the extension on.
#
#  Usage:
#    ./build.sh                # build into ./build/
#    ./build.sh install        # build, install to ~/Applications, and
#                              # register the extension (see note above about
#                              # the one manual Settings toggle still needed)
#
#  Environment:
#    CONFIG=Release|Debug          (default: Debug)
#    UNIVERSAL=1                   # build a universal (arm64 + x86_64) binary
#    BUNDLE_ID=...                 # override the host app's bundle identifier
#    EXTENSION_BUNDLE_ID=...       # override the extension's bundle identifier
#                                  # (default: $BUNDLE_ID.PreviewExtension)
#    APPLICATIONS_DIR=...          # install destination (default: ~/Applications)
#
#  The resulting bundles replicate what Xcode produces for an
#  com.apple.product-type.app-extension embedded in a
#  com.apple.product-type.application: PIE Mach-O executables (the extension's
#  entry point is Foundation's _NSExtensionMain), packaged and ad-hoc signed
#  for local use — extension first, then the outer app, matching Xcode's
#  sign-inner-before-outer order.
# =============================================================================
setopt err_exit no_unset

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
CONFIG="${CONFIG:-Debug}"
ROOT="${0:A:h}"
EXT_SRC_DIR="$ROOT/QLCodePreview"
APP_SRC_DIR="$ROOT/QLCodePreviewApp"
BUILD_DIR="$ROOT/build"

HOST_APP_NAME="QLCodePreview"
EXT_NAME="QLCodePreviewExtension"
HOST_BUNDLE_ID="${BUNDLE_ID:-com.konstruuktlabs.QLCodePreview}"
EXT_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-${HOST_BUNDLE_ID}.PreviewExtension}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
# A timestamp, not a fixed "1": LaunchServices appears to key its "have I
# already scanned this bundle" cache partly off CFBundleVersion, so a build
# that changes Info.plist (e.g. adds a UTI declaration) without also bumping
# this can get silently skipped on re-registration. Always changing it
# forces LaunchServices to treat every install as new.
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-$(date +%Y%m%d%H%M%S)}"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS="12.0"   # QLPreviewProvider / QLPreviewReply require macOS 12.0+

# Build architectures. Default: the host architecture.
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi
ARCH_FLAGS=()
for a in "${ARCHS[@]}"; ARCH_FLAGS+=(-arch "$a")

# -----------------------------------------------------------------------------
# Prepare directories
# -----------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
APP_BUNDLE="$BUILD_DIR/$HOST_APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS_DIR="$APP_CONTENTS/MacOS"
APP_RESOURCES_DIR="$APP_CONTENTS/Resources"
PLUGINS_DIR="$APP_CONTENTS/PlugIns"

EXT_BUNDLE="$PLUGINS_DIR/$EXT_NAME.appex"
EXT_CONTENTS="$EXT_BUNDLE/Contents"
EXT_MACOS_DIR="$EXT_CONTENTS/MacOS"
EXT_RESOURCES_DIR="$EXT_CONTENTS/Resources"

OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$EXT_MACOS_DIR" "$EXT_RESOURCES_DIR" "$OBJ_DIR"

# -----------------------------------------------------------------------------
# Compiler flags shared by both targets
# -----------------------------------------------------------------------------
COMMON_CFLAGS=(
    -isysroot "$SDKROOT"
    -mmacosx-version-min="$MIN_MACOS"
    -fobjc-arc
    -fmodules
    -fobjc-weak
    -Wno-deprecated-declarations
)
if [[ "$CONFIG" == "Debug" ]]; then
    COMMON_CFLAGS+=(-DDEBUG=1 -O0 -g)
else
    COMMON_CFLAGS+=(-DNDEBUG -O2)
fi

# -----------------------------------------------------------------------------
# 1. Build the extension (QLCodePreviewExtension.appex)
# -----------------------------------------------------------------------------
echo "▶ Compiling extension ($CONFIG, arch ${(j: :)ARCHS})…"
EXT_SOURCES=(
    "$EXT_SRC_DIR/QLCCConfiguration.m"
    "$EXT_SRC_DIR/QLCCTheme.m"
    "$EXT_SRC_DIR/QLCCHighlighter.m"
    "$EXT_SRC_DIR/QLCodePreviewProvider.m"
)
EXT_OBJ_FILES=()
for src in "${EXT_SOURCES[@]}"; do
    obj="$OBJ_DIR/ext_$(basename "${src%.m}").o"
    # -fapplication-extension marks the object/binary app-extension-safe —
    # required (along with sandboxing + hardened runtime below) for PlugInKit
    # to accept this as a real App Extension on macOS 26.
    clang "${ARCH_FLAGS[@]}" "${COMMON_CFLAGS[@]}" -fapplication-extension -I "$EXT_SRC_DIR" -c "$src" -o "$obj"
    EXT_OBJ_FILES+=("$obj")
done

echo "▶ Linking $EXT_NAME (extension)…"
EXT_EXE="$EXT_MACOS_DIR/$EXT_NAME"
clang "${ARCH_FLAGS[@]}" \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min="$MIN_MACOS" \
    -fobjc-arc \
    -fapplication-extension \
    -e _NSExtensionMain \
    "${EXT_OBJ_FILES[@]}" \
    -framework Cocoa \
    -framework QuickLookUI \
    -framework UniformTypeIdentifiers \
    -framework CoreGraphics \
    -o "$EXT_EXE"
if [[ "$CONFIG" == "Release" ]]; then
    strip -x "$EXT_EXE"
fi

echo "▶ Generating extension Info.plist…"
EXT_PLIST="$EXT_CONTENTS/Info.plist"
sed \
    -e "s|\\\$(DEVELOPMENT_LANGUAGE)|en|g" \
    -e "s|\\\$(EXECUTABLE_NAME)|$EXT_NAME|g" \
    -e "s|\\\$(PRODUCT_BUNDLE_IDENTIFIER)|$EXT_BUNDLE_ID|g" \
    -e "s|\\\$(PRODUCT_MODULE_NAME)|$EXT_NAME|g" \
    -e "s|\\\$(PRODUCT_NAME)|$EXT_NAME|g" \
    -e "s|\\\$(MARKETING_VERSION)|$MARKETING_VERSION|g" \
    -e "s|\\\$(CURRENT_PROJECT_VERSION)|$CURRENT_PROJECT_VERSION|g" \
    "$EXT_SRC_DIR/Info.plist" > "$EXT_PLIST"
plutil -lint "$EXT_PLIST"

echo "▶ Code signing extension (ad-hoc, sandboxed, hardened runtime)…"
ENT_PATH="$EXT_SRC_DIR/QLCodePreviewExtension.entitlements"
codesign --force --sign - \
    --identifier "$EXT_BUNDLE_ID" \
    --entitlements "$ENT_PATH" \
    --options runtime \
    --timestamp=none \
    "$EXT_BUNDLE"

# -----------------------------------------------------------------------------
# 2. Build the host app (QLCodePreview.app) with the extension embedded
# -----------------------------------------------------------------------------
echo "▶ Compiling host app…"
# The host app also builds its "Custom File Types" UI on top of
# QLCCHighlighter (for the supported-language list) and QLCCConfiguration
# (for the shared preferences domain/key constants) — reused straight from
# the extension's sources, compiled as plain (non-app-extension) objects.
APP_SOURCES=(
    "$APP_SRC_DIR/main.m"
    "$APP_SRC_DIR/FileTypesWindowController.m"
    "$APP_SRC_DIR/PreferencesWindowController.m"
    "$EXT_SRC_DIR/QLCCHighlighter.m"
    "$EXT_SRC_DIR/QLCCConfiguration.m"
    "$EXT_SRC_DIR/QLCCTheme.m"
)
APP_OBJ_FILES=()
for src in "${APP_SOURCES[@]}"; do
    obj="$OBJ_DIR/host_$(basename "${src%.m}").o"
    clang "${ARCH_FLAGS[@]}" "${COMMON_CFLAGS[@]}" -I "$APP_SRC_DIR" -I "$EXT_SRC_DIR" -c "$src" -o "$obj"
    APP_OBJ_FILES+=("$obj")
done

# -----------------------------------------------------------------------------
# 2.5. Self-test: automated regression harness for the tokenizer
#
#  Renders fixed snippets per language against a fixed theme and asserts the
#  expected colour spans appear. This exists because a hidden extra
#  capturing group in one language's regex has, twice, silently broken ALL
#  highlighting for that language — a mistake that's easy to make and easy
#  to miss by eye. A failure here aborts the build before packaging/signing.
# -----------------------------------------------------------------------------
echo "▶ Compiling and running tokenizer self-tests…"
TEST_SRC="$ROOT/tests/qlcc_selftest.m"
TEST_OBJ="$OBJ_DIR/qlcc_selftest.o"
clang "${ARCH_FLAGS[@]}" "${COMMON_CFLAGS[@]}" -I "$EXT_SRC_DIR" -c "$TEST_SRC" -o "$TEST_OBJ"

# Sources the self-test links against. The first three are already compiled
# as host_*.o by step 2; the provider is extension-only (not in APP_SOURCES),
# so compile it here on demand. Deriving the object list from this single
# array (rather than hardcoding host_*.o names in the link line) means a
# rename only needs editing here, not the link step too.
TEST_LIB_SOURCES=(
    "$EXT_SRC_DIR/QLCCHighlighter.m"
    "$EXT_SRC_DIR/QLCCConfiguration.m"
    "$EXT_SRC_DIR/QLCCTheme.m"
    "$EXT_SRC_DIR/QLCodePreviewProvider.m"
)
TEST_LIB_OBJ=()
for src in "${TEST_LIB_SOURCES[@]}"; do
    obj="$OBJ_DIR/host_$(basename "${src%.m}").o"
    [[ -f "$obj" ]] || \
        clang "${ARCH_FLAGS[@]}" "${COMMON_CFLAGS[@]}" -I "$EXT_SRC_DIR" -c "$src" -o "$obj"
    TEST_LIB_OBJ+=("$obj")
done

TEST_EXE="$OBJ_DIR/qlcc_selftest"
clang "${ARCH_FLAGS[@]}" \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min="$MIN_MACOS" \
    -fobjc-arc \
    "$TEST_OBJ" \
    "${TEST_LIB_OBJ[@]}" \
    -framework Cocoa \
    -framework UniformTypeIdentifiers \
    -framework QuickLookUI \
    -o "$TEST_EXE"

if ! "$TEST_EXE"; then
    echo "✗ Self-tests FAILED — aborting build." >&2
    exit 1
fi
echo "✓ Self-tests passed."

echo "▶ Linking $HOST_APP_NAME (host app)…"
APP_EXE="$APP_MACOS_DIR/$HOST_APP_NAME"
clang "${ARCH_FLAGS[@]}" \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min="$MIN_MACOS" \
    -fobjc-arc \
    "${APP_OBJ_FILES[@]}" \
    -framework Cocoa \
    -framework UniformTypeIdentifiers \
    -o "$APP_EXE"
if [[ "$CONFIG" == "Release" ]]; then
    strip -x "$APP_EXE"
fi

echo "▶ Generating host Info.plist…"
APP_PLIST="$APP_CONTENTS/Info.plist"
sed \
    -e "s|\\\$(DEVELOPMENT_LANGUAGE)|en|g" \
    -e "s|\\\$(EXECUTABLE_NAME)|$HOST_APP_NAME|g" \
    -e "s|\\\$(PRODUCT_BUNDLE_IDENTIFIER)|$HOST_BUNDLE_ID|g" \
    -e "s|\\\$(PRODUCT_MODULE_NAME)|$HOST_APP_NAME|g" \
    -e "s|\\\$(PRODUCT_NAME)|$HOST_APP_NAME|g" \
    -e "s|\\\$(MARKETING_VERSION)|$MARKETING_VERSION|g" \
    -e "s|\\\$(CURRENT_PROJECT_VERSION)|$CURRENT_PROJECT_VERSION|g" \
    "$APP_SRC_DIR/Info.plist" > "$APP_PLIST"
plutil -lint "$APP_PLIST"

echo "▶ Code signing $HOST_APP_NAME.app (ad-hoc, sealing embedded extension)…"
HOST_ENT_PATH="$APP_SRC_DIR/QLCodePreview.entitlements"
codesign --force --sign - \
    --identifier "$HOST_BUNDLE_ID" \
    --entitlements "$HOST_ENT_PATH" \
    "$APP_BUNDLE"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
echo
echo "✓ Built: $APP_BUNDLE"
echo "  $(file -b "$APP_EXE")"
echo "  Host bundle id: $HOST_BUNDLE_ID   version: $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)"
echo "  Embedded extension: $EXT_BUNDLE"
echo "  $(file -b "$EXT_EXE")"
echo "  Extension bundle id: $EXT_BUNDLE_ID"

# -----------------------------------------------------------------------------
# Optional install: copy to ~/Applications, launch once to register with
# PlugInKit, explicitly enable the extension, and reset Quick Look.
# -----------------------------------------------------------------------------
if [[ "${1:-}" == "install" ]]; then
    LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    DEST_DIR="${APPLICATIONS_DIR:-$HOME/Applications}"
    DEST_APP="$DEST_DIR/$HOST_APP_NAME.app"

    # Unregister any previous copy first — lsregister/pluginkit key off bundle
    # *path*, so a stale registration for an old copy at this same path can
    # otherwise linger and mask the new one.
    if [[ -d "$DEST_APP" ]]; then
        "$LSREG" -u "$DEST_APP" >/dev/null 2>&1 || true
    fi

    mkdir -p "$DEST_DIR"
    rm -rf "$DEST_APP"
    cp -R "$APP_BUNDLE" "$DEST_DIR/"
    echo
    echo "✓ Installed to $DEST_APP"

    echo "  Launching once…"
    open "$DEST_APP"
    sleep 1

    # `open` alone is not reliable for getting a *new* extension noticed —
    # explicitly force LaunchServices to (re-)index the bundle first. This is
    # the step PlugInKit registration actually depends on; skipping it is why
    # `pluginkit -a` can silently do nothing even though the app launches
    # fine and is correctly signed.
    #
    # A plain `-f "$DEST_APP"` (force re-scan of just this bundle) turned out
    # to not be reliable across rebuilds either — LaunchServices seems to key
    # part of its "have I already seen this" cache off CFBundleVersion/path,
    # so Info.plist changes (like adding a new UTI declaration) can silently
    # fail to take effect on a re-install even with -f. `-kill -r` forces
    # lsd to restart and fully rebuild its database across the domains that
    # matter for a per-user install, which is slower but actually reliable.
    echo "  Rebuilding the LaunchServices database (this can take a few seconds)…"
    "$LSREG" -kill -r -domain local -domain user >/dev/null 2>&1 || true
    echo "  Registering with LaunchServices (lsregister -f)…"
    "$LSREG" -f "$DEST_APP"

    echo "  Registering extension with PlugInKit…"
    pluginkit -a "$DEST_APP/Contents/PlugIns/$EXT_NAME.appex"
    pluginkit -e use -i "$EXT_BUNDLE_ID" >/dev/null 2>&1 || true

    echo "  Resetting Quick Look (qlmanage -r)…"
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
    killall -9 com.apple.quicklook.ThumbnailsAgent >/dev/null 2>&1 || true
    killall Finder >/dev/null 2>&1 || true

    echo
    echo "=== registered extensions matching qlcodepreview ==="
    pluginkit -mAvvv 2>&1 | grep -B1 -A4 -i qlcodepreview || echo "  (still not showing — see troubleshooting below)"

    echo
    echo "  One-time manual step (macOS won't let a script do this part):"
    echo "  System Settings → General → Login Items & Extensions → Quick Look"
    echo "  → toggle ON \"QLCodePreview Extension\"."
    echo "  Then test directly with:  qlmanage -p path/to/file.swift"
fi
