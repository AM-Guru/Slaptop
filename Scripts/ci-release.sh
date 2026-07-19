#!/bin/bash

set -euo pipefail
umask 077

required=(
  GITHUB_WORKSPACE
  GITHUB_OUTPUT
  GITHUB_RUN_NUMBER
  GITHUB_SHA
  RUNNER_TEMP
  APPLE_TEAM_ID
  DEVELOPER_ID_APPLICATION
  DEVELOPER_ID_P12_BASE64
  DEVELOPER_ID_P12_PASSWORD
  APP_STORE_CONNECT_PRIVATE_KEY_BASE64
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required release environment value: ${name}" >&2
    exit 1
  fi
done

case "${GITHUB_RUN_NUMBER}" in
  *[!0-9]*|'')
    echo "GITHUB_RUN_NUMBER must be numeric." >&2
    exit 1
    ;;
esac

if [[ "${DEVELOPER_ID_APPLICATION}" != Developer\ ID\ Application:*"(${APPLE_TEAM_ID})" ]]; then
  echo "The Developer ID identity does not match APPLE_TEAM_ID." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${RUNNER_TEMP%/}/slaptop-release.XXXXXX")"
DERIVED_DATA="${WORK_DIR}/DerivedData"
KEYCHAIN_PATH="${WORK_DIR}/release-signing.keychain-db"
P12_PATH="${WORK_DIR}/developer-id.p12"
ASC_KEY_PATH="${WORK_DIR}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
APP_ZIP_PATH="${WORK_DIR}/Slaptop-notarization.zip"
DMG_PATH="${WORK_DIR}/Slaptop.dmg"
MOUNT_POINT="${WORK_DIR}/mounted-dmg"
DMG_BACKGROUND_PATH="${GITHUB_WORKSPACE}/Distribution/DMG/background.png"
DMGBUILD_REQUIREMENTS="${GITHUB_WORKSPACE}/Distribution/dmg-requirements.txt"
DMGBUILD_SETTINGS="${GITHUB_WORKSPACE}/Distribution/dmg-settings.py"
DMGBUILD_VENV="${WORK_DIR}/dmgbuild-venv"
DMG_LAYOUT_VERIFIER="${GITHUB_WORKSPACE}/Scripts/verify-dmg-layout.py"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
ORIGINAL_KEYCHAINS=()
DMG_IS_MOUNTED=false
APP_PATH=""
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'

while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  keychain="${keychain%\"*}"
  [[ -n "${keychain}" ]] && ORIGINAL_KEYCHAINS+=("${keychain}")
done < <(security list-keychains -d user)

cleanup() {
  local exit_code=$?
  set +e
  if [[ "${DMG_IS_MOUNTED}" == true ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet
  fi
  if ((${#ORIGINAL_KEYCHAINS[@]})); then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  fi
  if [[ -n "${APP_PATH}" && -d "${APP_PATH}" ]]; then
    "${LSREGISTER}" -u "${APP_PATH}"
  fi
  security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1
  rm -rf "${WORK_DIR}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "${DEVELOPER_ID_P12_BASE64}" | /usr/bin/base64 -D > "${P12_PATH}"
printf '%s' "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64}" | /usr/bin/base64 -D > "${ASC_KEY_PATH}"
chmod 600 "${P12_PATH}" "${ASC_KEY_PATH}"

security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security import "${P12_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${DEVELOPER_ID_P12_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}" >/dev/null
security list-keychains -d user -s "${KEYCHAIN_PATH}" "${ORIGINAL_KEYCHAINS[@]}"

if ! security find-identity -v -p codesigning "${KEYCHAIN_PATH}" \
  | grep -Fq "\"${DEVELOPER_ID_APPLICATION}\""; then
  echo "The imported PKCS#12 does not contain ${DEVELOPER_ID_APPLICATION}." >&2
  exit 1
fi

for path in \
  "${DMG_BACKGROUND_PATH}" \
  "${DMGBUILD_REQUIREMENTS}" \
  "${DMGBUILD_SETTINGS}" \
  "${DMG_LAYOUT_VERIFIER}"; do
  if [[ ! -f "${path}" ]]; then
    echo "Missing required DMG packaging file: ${path}" >&2
    exit 1
  fi
done

PYTHON3_PATH="$(xcrun --find python3)"
"${PYTHON3_PATH}" -m venv "${DMGBUILD_VENV}"
"${DMGBUILD_VENV}/bin/python" -m pip install \
  --disable-pip-version-check \
  --require-hashes \
  --requirement "${DMGBUILD_REQUIREMENTS}"

# Keep imported keys private, but create the app and disk-image payload with
# normal distributable permissions.
umask 022
cd "${GITHUB_WORKSPACE}"
rm -f "${GITHUB_WORKSPACE}/Slaptop.dmg"
xcodegen generate

xcodebuild \
  -project Slaptop.xcodeproj \
  -scheme Slaptop \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  clean build \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

APP_PATH="${DERIVED_DATA}/Build/Products/Release/Slaptop.app"
HELPER_PATH="${APP_PATH}/Contents/Resources/SlaptopSensorDaemon"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
APP_LICENSE_PATH="${APP_PATH}/Contents/Resources/LICENSE.txt"
APP_THIRD_PARTY_NOTICES_PATH="${APP_PATH}/Contents/Resources/THIRD_PARTY_NOTICES.md"

[[ -d "${APP_PATH}" ]]
[[ -x "${HELPER_PATH}" ]]
[[ -f "${APP_PATH}/Contents/Library/LaunchDaemons/guru.am.slaptop.sensor-daemon.plist" ]]

/usr/bin/install -m 0644 "${GITHUB_WORKSPACE}/LICENSE" "${APP_LICENSE_PATH}"
/usr/bin/install -m 0644 "${GITHUB_WORKSPACE}/THIRD_PARTY_NOTICES.md" "${APP_THIRD_PARTY_NOTICES_PATH}"
[[ -f "${APP_LICENSE_PATH}" ]]
[[ -f "${APP_THIRD_PARTY_NOTICES_PATH}" ]]

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER}" "${INFO_PLIST}"

codesign \
  --force \
  --sign "${DEVELOPER_ID_APPLICATION}" \
  --identifier guru.am.slaptop.sensor-daemon \
  --options runtime \
  --timestamp \
  "${HELPER_PATH}"

codesign \
  --force \
  --sign "${DEVELOPER_ID_APPLICATION}" \
  --identifier guru.am.slaptop \
  --options runtime \
  --timestamp \
  "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
SIGNED_TEAM_ID="$(codesign -dvv "${APP_PATH}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "${SIGNED_TEAM_ID}" != "${APPLE_TEAM_ID}" ]]; then
  echo "Signed app team ${SIGNED_TEAM_ID:-<missing>} does not match ${APPLE_TEAM_ID}." >&2
  exit 1
fi

notarize() {
  local artifact_path="$1"
  local label="$2"
  local result_path="${WORK_DIR}/${label}-notarization.json"
  local submission_id
  local submission_status

  if ! xcrun notarytool submit "${artifact_path}" \
    --key "${ASC_KEY_PATH}" \
    --key-id "${APP_STORE_CONNECT_KEY_ID}" \
    --issuer "${APP_STORE_CONNECT_ISSUER_ID}" \
    --wait \
    --output-format json > "${result_path}"; then
    cat "${result_path}" >&2 || true
    exit 1
  fi

  cat "${result_path}"
  submission_id="$(plutil -extract id raw -o - "${result_path}")"
  submission_status="$(plutil -extract status raw -o - "${result_path}")"
  if [[ "${submission_status}" != "Accepted" ]]; then
    xcrun notarytool log "${submission_id}" \
      --key "${ASC_KEY_PATH}" \
      --key-id "${APP_STORE_CONNECT_KEY_ID}" \
      --issuer "${APP_STORE_CONNECT_ISSUER_ID}" \
      "${WORK_DIR}/${label}-notarization-log.json" || true
    cat "${WORK_DIR}/${label}-notarization-log.json" >&2 || true
    exit 1
  fi
}

ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP_PATH}"
notarize "${APP_ZIP_PATH}" app
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl -a -vvv -t exec "${APP_PATH}"

"${DMGBUILD_VENV}/bin/dmgbuild" \
  --no-hidpi \
  --detach-retries 10 \
  --settings "${DMGBUILD_SETTINGS}" \
  -D "app_path=${APP_PATH}" \
  -D "background_path=${DMG_BACKGROUND_PATH}" \
  Slaptop \
  "${DMG_PATH}"

codesign \
  --force \
  --sign "${DEVELOPER_ID_APPLICATION}" \
  --timestamp \
  "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"

notarize "${DMG_PATH}" dmg
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
spctl -a -vvv -t open --context context:primary-signature "${DMG_PATH}"

mkdir -p "${MOUNT_POINT}"
hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "${MOUNT_POINT}" \
  "${DMG_PATH}" >/dev/null
DMG_IS_MOUNTED=true

VISIBLE_ENTRY_COUNT="$(find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 ! -name '.*' -print | wc -l | tr -d '[:space:]')"
APPLICATIONS_LINK="$(readlink "${MOUNT_POINT}/Applications" 2>/dev/null || true)"
if [[ "${VISIBLE_ENTRY_COUNT}" != "2" \
  || ! -d "${MOUNT_POINT}/Slaptop.app" \
  || "${APPLICATIONS_LINK}" != "/Applications" \
  || ! -f "${MOUNT_POINT}/.background.png" ]] \
  || ! cmp -s "${DMG_BACKGROUND_PATH}" "${MOUNT_POINT}/.background.png"; then
  echo "Slaptop.dmg must contain the app, Applications shortcut, and background asset." >&2
  find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 -print >&2
  exit 1
fi
"${DMGBUILD_VENV}/bin/python" "${DMG_LAYOUT_VERIFIER}" "${MOUNT_POINT}"

hdiutil detach "${MOUNT_POINT}" -quiet
DMG_IS_MOUNTED=false
ditto "${DMG_PATH}" "${GITHUB_WORKSPACE}/Slaptop.dmg"

RELEASE_TAG="v${APP_VERSION}-build.${GITHUB_RUN_NUMBER}"
RELEASE_TITLE="Slaptop ${APP_VERSION} (build ${GITHUB_RUN_NUMBER})"
{
  echo "release_tag=${RELEASE_TAG}"
  echo "release_title=${RELEASE_TITLE}"
} >> "${GITHUB_OUTPUT}"

shasum -a 256 "${GITHUB_WORKSPACE}/Slaptop.dmg"
