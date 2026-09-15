#!/bin/zsh -f
# =============================================================================
#  rebuild-icon.sh — regenerate the compiled icon artifacts from the Icon
#  Composer source document (QLCodePreviewApp/Assets/AppIcon.icon).
#
#  Writes into QLCodePreviewApp/Assets/compiled/:
#    Assets.car    — CAR renditions macOS 26 renders as the Liquid Glass icon
#    AppIcon.icns  — flattened fallback for pre-26 macOS releases
#
#  build.sh installs these committed artifacts into the app bundle instead
#  of compiling the icon at build time: actool's ibtoold backend proved
#  flaky on CI runners, and older Xcode's actool silently skips the icns
#  fallback. Run this after editing the .icon in Icon Composer, then commit
#  the document and both artifacts together — they are the same change.
#
#  Requires Xcode 26.6 or newer (verified emitting both artifacts; 26.3
#  compiles the .car but skips the icns).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ICON_SRC="QLCodePreviewApp/Assets/AppIcon.icon"
OUT_DIR="QLCodePreviewApp/Assets/compiled"
MIN_MACOS="$(sed -n 's/^MIN_MACOS="\(.*\)"/\1/p' build.sh | head -1)"

ACTOOL="$(xcrun --find actool 2>/dev/null)" || ACTOOL=""
if [[ -z "$ACTOOL" || ! -d "$ICON_SRC" ]]; then
    echo "✗ actool or $ICON_SRC missing — install and select Xcode 26.6+." >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
echo "▶ Compiling $ICON_SRC (min macOS ${MIN_MACOS:-12.0})…"
"$ACTOOL" --compile "$STAGE" \
    --platform macosx \
    --minimum-deployment-target "${MIN_MACOS:-12.0}" \
    --app-icon AppIcon \
    --output-partial-info-plist "$STAGE/partial-info.plist" \
    "$ICON_SRC" >/dev/null

[[ -f "$STAGE/Assets.car" ]] || { echo "✗ actool produced no Assets.car." >&2; exit 1; }
if [[ ! -f "$STAGE/AppIcon.icns" ]]; then
    echo "✗ actool produced no AppIcon.icns — this Xcode's actool skips the fallback." >&2
    echo "  Use Xcode 26.6+ (xcode-select -s /Applications/Xcode.app)." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
cp "$STAGE/Assets.car" "$STAGE/AppIcon.icns" "$OUT_DIR/"
echo "✓ $OUT_DIR/Assets.car   ($(du -h "$OUT_DIR/Assets.car" | cut -f1))"
echo "✓ $OUT_DIR/AppIcon.icns ($(du -h "$OUT_DIR/AppIcon.icns" | cut -f1))"
echo "  Commit them together with the .icon document."
