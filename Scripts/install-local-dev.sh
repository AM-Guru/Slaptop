#!/bin/bash

set -euo pipefail
umask 022

if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "Slaptop-Dev is a local-only build and cannot be built in CI." >&2
  exit 1
fi

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly work_directory="$(mktemp -d /tmp/slaptop-local-dev.XXXXXX)"
readonly derived_data="${work_directory}/DerivedData"
readonly built_app="${derived_data}/Build/Products/Release/Slaptop-Dev.app"
readonly destination="/Applications/Slaptop-Dev.app"
readonly backup="${work_directory}/Slaptop-Dev.previous.app"
install_started=false

cleanup() {
  local exit_code=$?
  trap - EXIT
  if [[ "${exit_code}" -ne 0 && "${install_started}" == true ]]; then
    /bin/rm -rf "${destination}"
    if [[ -e "${backup}" ]]; then
      /bin/mv "${backup}" "${destination}"
    fi
  fi
  /bin/rm -rf "${work_directory}"
  exit "${exit_code}"
}
trap cleanup EXIT

if /usr/bin/pgrep -f '^/Applications/Slaptop-Dev.app/Contents/MacOS/Slaptop-Dev$' >/dev/null; then
  echo "Quit Slaptop-Dev before reinstalling it." >&2
  exit 1
fi

cd "${repository_root}"
/usr/bin/xcodebuild \
  -project Slaptop.xcodeproj \
  -scheme Slaptop \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${derived_data}" \
  clean build \
  SLAPTOP_PRODUCT_NAME=Slaptop-Dev \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_DEV'

[[ -d "${built_app}" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${built_app}/Contents/Info.plist")" == "Slaptop-Dev" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${built_app}/Contents/Info.plist")" == "guru.am.slaptop" ]]
/usr/bin/codesign --verify --deep --strict --verbose=2 "${built_app}"

if [[ -e "${destination}" ]]; then
  /bin/mv "${destination}" "${backup}"
fi
install_started=true

/usr/bin/ditto "${built_app}" "${destination}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${destination}"
if [[ -e "${backup}" ]]; then
  /bin/rm -rf "${backup}"
fi
install_started=false

echo "Installed ${destination}"
