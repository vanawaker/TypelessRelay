#!/usr/bin/env bash
# Install and launch TypelessRelay.app on the local Mac
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TypelessRelay"
BUNDLE_ID="xyz.spaceshuttle.typelessrelay"
STAGE_APP="${DIR}/build/${APP_NAME}.app"
DEST_APP="/Applications/${APP_NAME}.app"

if [ ! -d "${STAGE_APP}" ]; then
  echo "Missing ${STAGE_APP}. Run ./scripts/build.sh first."
  exit 1
fi

pkill -x "${APP_NAME}" || true
rm -rf "${DEST_APP}"
cp -R "${STAGE_APP}" "${DEST_APP}"
xattr -cr "${DEST_APP}" || true

CERT="${TYPELESSRELAY_SIGN_IDENTITY:--}"
codesign --force --deep --sign "${CERT}" "${DEST_APP}"
if [ "${CERT}" = "-" ]; then
  tccutil reset Accessibility "${BUNDLE_ID}" || true
fi
open "${DEST_APP}" </dev/null >/dev/null 2>&1
echo "==> Installed and launched locally: ${DEST_APP} (sign: ${CERT})"
