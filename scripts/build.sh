#!/usr/bin/env bash
# TypelessRelay build script: icon -> Universal binary (arm64 + x86_64) -> .app bundle -> codesign
# Optional stable signing identity: export TYPELESSRELAY_SIGN_IDENTITY="Your Code Signing Cert"
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TypelessRelay"
BUNDLE_ID="xyz.spaceshuttle.typelessrelay"
VERSION="1.2.0"
BUILD="${DIR}/build"
STAGE_APP="${BUILD}/${APP_NAME}.app"

mkdir -p "${BUILD}" "${DIR}/assets"

echo "==> 1. Generating icon assets (.png & .icns)"
if [ ! -f "${DIR}/assets/icon-1024.png" ] || [ "${REGEN_ICON:-0}" = "1" ]; then
  swift "${DIR}/assets/make_icon.swift" "${DIR}/assets/icon-1024.png"
fi

ICONSET="${BUILD}/${APP_NAME}.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
for sz in 16 32 128 256 512; do
  sips -z "${sz}" "${sz}" "${DIR}/assets/icon-1024.png" --out "${ICONSET}/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz * 2))
  sips -z "${dbl}" "${dbl}" "${DIR}/assets/icon-1024.png" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
done
if ! iconutil -c icns "${ICONSET}" -o "${DIR}/assets/${APP_NAME}.icns" 2>/dev/null; then
  python3 - "${ICONSET}" "${DIR}/assets/${APP_NAME}.icns" <<'PY'
import struct, sys, os
iconset, out_icns = sys.argv[1], sys.argv[2]
mapping = [
    (b"icp4", "icon_16x16.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"icp5", "icon_32x32.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic14", "icon_256x256@2x.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
]
chunks = bytearray()
for ostype, fname in mapping:
    with open(os.path.join(iconset, fname), "rb") as f:
        data = f.read()
    chunks += ostype + struct.pack(">I", len(data) + 8) + data
with open(out_icns, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
PY
fi

echo "==> 2. Compiling Swift universal binary (arm64 + x86_64)"
FRAMEWORKS=(-framework Cocoa -framework Carbon -framework ServiceManagement -framework SystemConfiguration)
swiftc -O -target arm64-apple-macos13.0 "${FRAMEWORKS[@]}" "${DIR}/src/${APP_NAME}.swift" -o "${BUILD}/${APP_NAME}-arm64"
swiftc -O -target x86_64-apple-macos13.0 "${FRAMEWORKS[@]}" "${DIR}/src/${APP_NAME}.swift" -o "${BUILD}/${APP_NAME}-x86_64"
lipo -create "${BUILD}/${APP_NAME}-arm64" "${BUILD}/${APP_NAME}-x86_64" -output "${BUILD}/${APP_NAME}"

echo "==> 3. Packaging ${STAGE_APP}"
rm -rf "${STAGE_APP}"
mkdir -p \
  "${STAGE_APP}/Contents/MacOS" \
  "${STAGE_APP}/Contents/Resources/en.lproj" \
  "${STAGE_APP}/Contents/Resources/zh-Hans.lproj"

cp "${BUILD}/${APP_NAME}" "${STAGE_APP}/Contents/MacOS/${APP_NAME}"
cp "${DIR}/assets/${APP_NAME}.icns" "${STAGE_APP}/Contents/Resources/${APP_NAME}.icns"

cat > "${STAGE_APP}/Contents/Resources/en.lproj/InfoPlist.strings" <<'STR'
"NSLocalNetworkUsageDescription" = "Discover other Macs running TypelessRelay on your local network and relay dictated text for instant paste.";
STR

cat > "${STAGE_APP}/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STR'
"NSLocalNetworkUsageDescription" = "用于自动发现局域网内其他运行 TypelessRelay 的 Mac 并毫秒级接力粘贴语音文本。";
STR

cat > "${STAGE_APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Discover other Macs running TypelessRelay on your local network and relay dictated text for instant paste.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 ZAX WEN</string>
</dict>
</plist>
PLIST

echo "==> 4. Code signing"
CERT="${TYPELESSRELAY_SIGN_IDENTITY:--}"
codesign --force --deep --sign "${CERT}" "${STAGE_APP}"

echo "==> Done: ${STAGE_APP} (arch: arm64 + x86_64, sign: ${CERT})"
