#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <BikeComputer.app>" >&2
  exit 64
fi

APP_PATH="${1%/}"
WATCH_PATH="${APP_PATH}/Watch/BikeComputerWatch.app"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  if [[ ! -s "$1" ]]; then
    echo "missing release-container file: $1" >&2
    exit 1
  fi
}

require_file "${APP_PATH}/Info.plist"
require_file "${APP_PATH}/BikeComputer"
require_file "${APP_PATH}/PrivacyInfo.xcprivacy"
require_file "${WATCH_PATH}/Info.plist"
require_file "${WATCH_PATH}/BikeComputerWatch"
require_file "${WATCH_PATH}/PrivacyInfo.xcprivacy"
require_file "${WATCH_PATH}/Assets.car"

cmp "${SOURCE_ROOT}/BikeComputer/BikeComputer/PrivacyInfo.xcprivacy" \
  "${APP_PATH}/PrivacyInfo.xcprivacy"
cmp "${SOURCE_ROOT}/BikeComputer/BikeComputerWatch/PrivacyInfo.xcprivacy" \
  "${WATCH_PATH}/PrivacyInfo.xcprivacy"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Info.plist")" \
  == "LetItRide.BikeComputer" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${WATCH_PATH}/Info.plist")" \
  == "LetItRide.BikeComputer.watchkitapp" ]]
WATCH_BACKGROUND_MODES="$(
  /usr/libexec/PlistBuddy -c 'Print :WKBackgroundModes' "${WATCH_PATH}/Info.plist"
)"
[[ "${WATCH_BACKGROUND_MODES}" == *"workout-processing"* ]]
WATCH_PRIMARY_ICON="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' \
    "${WATCH_PATH}/Info.plist"
)"
if [[ "${WATCH_PRIMARY_ICON}" != "AppIcon" ]]; then
  echo "invalid Watch primary icon metadata: ${WATCH_PRIMARY_ICON}" >&2
  exit 1
fi

echo "Release iPhone container and embedded Watch app verified"
