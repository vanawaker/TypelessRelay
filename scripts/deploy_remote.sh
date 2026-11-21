#!/usr/bin/env bash
# Deploy and launch TypelessRelay.app on another Mac over SSH
# Usage:
#   ./scripts/deploy_remote.sh user@remote-mac.local
#   or set TYPELESSRELAY_REMOTE in your shell or gitignored .env.local
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TypelessRelay"
BUNDLE_ID="xyz.spaceshuttle.typelessrelay"
STAGE_APP="${DIR}/build/${APP_NAME}.app"

if [ -f "${DIR}/.env.local" ]; then
  # shellcheck disable=SC1091
  source "${DIR}/.env.local"
fi

REMOTE="${1:-${TYPELESSRELAY_REMOTE:-}}"
if [ -z "${REMOTE}" ]; then
  echo "Usage: $0 user@remote-mac-ip-or-host"
  echo "Tip:   Or save TYPELESSRELAY_REMOTE=\"user@host\" in .env.local (gitignored)."
  exit 1
fi

if [ ! -d "${STAGE_APP}" ]; then
  echo "Missing ${STAGE_APP}. Run ./scripts/build.sh first."
  exit 1
fi

CERT="${TYPELESSRELAY_SIGN_IDENTITY:--}"
echo "==> Packaging and deploying ${APP_NAME}.app to ${REMOTE} ..."
COPYFILE_DISABLE=1 tar -C "${DIR}/build" -czf - "${APP_NAME}.app" | ssh -o BatchMode=yes "${REMOTE}" "
  set -e
  pkill -x '${APP_NAME}' || true
  rm -rf '/Applications/${APP_NAME}.app'
  tar -C /Applications -xzf -
  xattr -cr '/Applications/${APP_NAME}.app' || true
  codesign --force --deep --sign '${CERT}' '/Applications/${APP_NAME}.app'
  if [ '${CERT}' = '-' ]; then
    tccutil reset Accessibility '${BUNDLE_ID}' || true
  fi
  open '/Applications/${APP_NAME}.app' </dev/null >/dev/null 2>&1
"
echo "==> Deployed and launched on ${REMOTE}!"
