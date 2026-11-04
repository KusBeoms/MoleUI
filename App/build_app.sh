#!/bin/bash
# Builds MoleUI.app (ad-hoc signed) with a bundled copy of the Mole CLI.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
MOLE_SRC="${MOLE_SRC:-$(cd .. && pwd)/Mole}"
OUT="build/MoleUI.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MoleUI"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/mole"
cp "$BIN" "$OUT/Contents/MacOS/MoleUI"

# Bundle only what `mo` needs at runtime (shell scripts); skip tests, docs, VCS.
rsync -rl --delete --no-perms --no-times \
  --include='/mo' --include='/mole' --include='/bin/***' --include='/lib/***' \
  --include='/scripts/***' --include='/LICENSE' --exclude='*' \
  "$MOLE_SRC/" "$OUT/Contents/Resources/mole/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MoleUI</string>
  <key>CFBundleDisplayName</key><string>MoleUI</string>
  <key>CFBundleIdentifier</key><string>dev.local.MoleUI</string>
  <key>CFBundleExecutable</key><string>MoleUI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>터미널에서 Mole 명령을 실행하기 위해 필요합니다.</string>
</dict></plist>
PLIST

# No developer certificate: sign ad hoc but pin the designated requirement to the bundle id,
# so macOS privacy grants (Full Disk Access etc.) survive rebuilds instead of resetting.
codesign --force --deep --sign - -r='designated => identifier "dev.local.MoleUI"' "$OUT" >/dev/null
echo "Built $OUT"
