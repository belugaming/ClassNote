#!/usr/bin/env bash
# Build Release + install to ~/Applications/ClassNote.app.
# Run: bash scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ Regenerating Xcode project..."
xcodegen generate >/dev/null

echo "→ Building Release (this takes ~30s)..."
xcodebuild -project ClassNote.xcodeproj \
           -scheme ClassNote \
           -configuration Release \
           -destination 'platform=macOS,arch=arm64' \
           -skipMacroValidation \
           build 2>&1 | tail -5

SRC=$(find ~/Library/Developer/Xcode/DerivedData -path "*Release/ClassNote.app" -type d 2>/dev/null | head -1)
if [[ -z "$SRC" ]]; then
    echo "✗ Couldn't find built ClassNote.app"
    exit 1
fi

DST=~/Applications
mkdir -p "$DST"

# Close running copy if any so the copy doesn't fail.
pkill -x ClassNote 2>/dev/null || true
sleep 1

echo "→ Installing to $DST/ClassNote.app..."
rm -rf "$DST/ClassNote.app"
cp -R "$SRC" "$DST/"

# Tell Launch Services this is a new, trusted app so Spotlight + TCC pick it up.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
    -f -R -trusted "$DST/ClassNote.app" 2>/dev/null || true

echo ""
echo "✓ Installed at $DST/ClassNote.app"
echo ""
echo "Opening it now..."
open "$DST/ClassNote.app"

cat <<MSG

-------------------------------------------------------------------
Next steps (one-time)
-------------------------------------------------------------------
1. When ClassNote asks for Microphone permission → Allow.
2. When you first try "System audio" recording, ClassNote will ask
   for Screen Recording permission → Allow, then restart the app.
3. Grant them ONCE to the copy in ~/Applications. The dev build in
   DerivedData is a separate app to macOS and will ask for its own
   grants — ignore that one.

Note: if you re-run this script (i.e. rebuild + reinstall), macOS
may re-ask for Screen Recording since the code signature changed.
That's macOS policy on ad-hoc signed apps; nothing to do about it
except run this less often.
-------------------------------------------------------------------
MSG
