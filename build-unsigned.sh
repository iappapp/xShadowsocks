#!/usr/bin/env bash
#
# Compiles every target without signing anything.
#
# Signing is what consumes free-account App IDs, so this is the loop to use while
# iterating on code: it never touches a provisioning profile, never talks to the
# developer portal, and never needs a team. It cannot produce an installable app —
# for that, open the project in Xcode and run on a device.
#
# Usage:
#   ./build-unsigned.sh            # all targets, Debug
#   ./build-unsigned.sh app        # just the app
#   ./build-unsigned.sh tests      # app + unit tests (build-for-testing)
#   ./build-unsigned.sh extension  # just the packet-tunnel extension
#   ./build-unsigned.sh all Release
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

TARGET="${1:-all}"
CONFIG="${2:-Debug}"

# Passing an empty identity plus disabling signing outright covers both the modern
# and legacy paths; CODE_SIGN_ENTITLEMENTS="" keeps entitlement processing (and its
# App Group validation) out of the build entirely.
NO_SIGN=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  CODE_SIGN_ENTITLEMENTS=""
  EXPANDED_CODE_SIGN_IDENTITY=""
  PROVISIONING_PROFILE_SPECIFIER=""
)

banner() {
  printf '\n\033[1m==> %s\033[0m\n' "$1"
}

build_app() {
  banner "xShadowsocks (app, $CONFIG)"
  xcodebuild -project xShadowsocks.xcodeproj \
    -scheme xShadowsocks \
    -destination 'generic/platform=iOS' \
    -configuration "$CONFIG" \
    "${NO_SIGN[@]}" \
    build
}

build_tests() {
  banner "xShadowsocksTests (unit tests, simulator)"
  # Runs on the simulator so the build does not need a device or a team.
  xcodebuild -project xShadowsocks.xcodeproj \
    -scheme xShadowsocks \
    -destination "platform=iOS Simulator,name=iPhone 16" \
    -configuration Debug \
    "${NO_SIGN[@]}" \
    build-for-testing
}

build_extension() {
  banner "xPacketTunnel (extension, $CONFIG)"
  # Built directly by target rather than by scheme: the extension is deliberately not
  # part of the app's build, so this is the only way to type-check it without signing.
  xcodebuild -project xShadowsocks.xcodeproj \
    -target xPacketTunnel \
    -sdk iphoneos \
    -configuration "$CONFIG" \
    "${NO_SIGN[@]}" \
    build
}

case "$TARGET" in
  all)
    build_app
    build_tests
    build_extension
    ;;
  app)       build_app ;;
  tests)     build_app; build_tests ;;
  extension) build_extension ;;
  *)
    echo "unknown target: $TARGET" >&2
    echo "usage: $0 [all|app|tests|extension] [Debug|Release]" >&2
    exit 2
    ;;
esac

banner "done — nothing was signed"
