#!/bin/bash
# Replaces the ad-hoc signature from build-app.sh with a Developer ID signature, then
# notarizes and staples the ticket so Gatekeeper accepts the app on other Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=".build/opencloak-app/OpenCloak.app"
IDENTITY_PREFIX="${OPENCLOAK_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${OPENCLOAK_NOTARY_PROFILE:-}"
NOTARIZE=1

for argument in "$@"; do
  case "$argument" in
    --skip-notarize) NOTARIZE=0 ;;
    --identity=*) IDENTITY_PREFIX="${argument#*=}" ;;
    --profile=*) PROFILE="${argument#*=}" ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/release-app.sh [--skip-notarize] [--identity=NAME] [--profile=KEYCHAIN_PROFILE]

Signs .build/opencloak-app/OpenCloak.app with a Developer ID certificate, enables the hardened
runtime, and keeps the Apple-events entitlement that website screens need. Unless
--skip-notarize is passed it then submits the app to Apple's notary service, staples the
ticket, and checks the result with spctl.

Environment:
  OPENCLOAK_SIGN_IDENTITY   codesigning identity prefix (default "Developer ID Application")
  OPENCLOAK_NOTARY_PROFILE  notarytool keychain profile from `xcrun notarytool store-credentials`
USAGE
      exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; exit 64 ;;
  esac
done

[[ -d "$APP" ]] || { echo "No app bundle at $APP. Run ./scripts/build-app.sh first." >&2; exit 1; }
[[ -f OpenCloak.entitlements ]] || { echo "Missing OpenCloak.entitlements." >&2; exit 1; }

MATCH="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY_PREFIX" | head -1 || true)"
if [[ -z "$MATCH" ]]; then
  echo "No codesigning identity beginning with \"$IDENTITY_PREFIX\" is installed." >&2
  echo "Installed identities:" >&2
  security find-identity -v -p codesigning >&2 || true
  echo "" >&2
  echo "A Developer ID Application certificate requires a paid Apple Developer account." >&2
  echo "Without one, the bundle stays ad-hoc signed and cannot be distributed." >&2
  exit 2
fi
IDENTITY_NAME="$(printf '%s\n' "$MATCH" | sed -n 's/.*"\(.*\)".*/\1/p')"

/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements OpenCloak.entitlements --sign "$IDENTITY_NAME" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
echo "Signed with hardened runtime as: $IDENTITY_NAME"

if [[ "$NOTARIZE" -eq 0 ]]; then
  echo "Notarization skipped. Gatekeeper still warns on other Macs until the ticket is stapled."
  exit 0
fi

if [[ -z "$PROFILE" ]]; then
  echo "Set OPENCLOAK_NOTARY_PROFILE to a notarytool keychain profile, or pass --skip-notarize." >&2
  exit 3
fi

ZIP="$(mktemp -t opencloak-notarize).zip"
trap 'rm -f "$ZIP"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
/usr/sbin/spctl -a -vvv -t exec "$APP"
echo "Notarized, stapled, and accepted by Gatekeeper: $APP"
