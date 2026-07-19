#!/bin/bash

set -euo pipefail
umask 077

required=(
  GITHUB_ACTIONS
  GITHUB_EVENT_NAME
  GITHUB_REPOSITORY
  GITHUB_REF
  GITHUB_REF_TYPE
  GITHUB_RUN_NUMBER
  GITHUB_SHA
  GITHUB_WORKSPACE
  RUNNER_TEMP
  APPLE_TEAM_ID
  APP_STORE_CONNECT_PRIVATE_KEY_BASE64
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required App Store QA environment value: ${name}" >&2
    exit 1
  fi
done

[[ "${GITHUB_ACTIONS}" == "true" ]]
[[ "${GITHUB_EVENT_NAME}" == "push" ]]
[[ "${GITHUB_REPOSITORY}" == "AM-Guru/Slaptop" ]]
[[ "${GITHUB_REF}" == "refs/heads/main" ]]
[[ "${GITHUB_REF_TYPE}" == "branch" ]]
[[ "${APPLE_TEAM_ID}" == "59A594LZGR" ]]
[[ "${GITHUB_RUN_NUMBER}" =~ ^[0-9]+$ ]]
[[ "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]]

work_dir="$(mktemp -d "${RUNNER_TEMP%/}/slaptop-app-store-qa.XXXXXX")"
derived_data="${work_dir}/DerivedData"
archive_path="${work_dir}/Slaptop.xcarchive"
export_path="${work_dir}/export"
asc_key_path="${work_dir}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"

cleanup() {
  local exit_code=$?
  rm -rf "${work_dir}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64}" | /usr/bin/base64 -D > "${asc_key_path}"
chmod 600 "${asc_key_path}"
/usr/bin/openssl pkey -in "${asc_key_path}" -noout >/dev/null

cd "${GITHUB_WORKSPACE}"
xcodegen generate

xcodebuild \
  -project Slaptop.xcodeproj \
  -scheme Slaptop \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${derived_data}" \
  -archivePath "${archive_path}" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${asc_key_path}" \
  -authenticationKeyID "${APP_STORE_CONNECT_KEY_ID}" \
  -authenticationKeyIssuerID "${APP_STORE_CONNECT_ISSUER_ID}" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}" \
  archive

app_path="${archive_path}/Products/Applications/Slaptop.app"
info_plist="${app_path}/Contents/Info.plist"
[[ -d "${app_path}" ]]
[[ -f "${info_plist}" ]]

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}")"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}")"
[[ "${bundle_id}" == "guru.am.slaptop" ]]
[[ "${build_number}" == "${GITHUB_RUN_NUMBER}" ]]
codesign --verify --deep --strict --verbose=2 "${app_path}"

if ! codesign -d --entitlements :- "${app_path}" 2>/dev/null \
  | plutil -extract com.apple.security.app-sandbox raw -o - - 2>/dev/null \
  | grep -Fxq true; then
  echo "::warning title=Mac App Store sandbox::The archived app is not sandboxed. Apple processing or review may reject this privileged-helper build; the upload is for internal QA only."
fi

xcodebuild \
  -exportArchive \
  -archivePath "${archive_path}" \
  -exportPath "${export_path}" \
  -exportOptionsPlist "${GITHUB_WORKSPACE}/Distribution/AppStoreQAExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${asc_key_path}" \
  -authenticationKeyID "${APP_STORE_CONNECT_KEY_ID}" \
  -authenticationKeyIssuerID "${APP_STORE_CONNECT_ISSUER_ID}"

echo "Uploaded Slaptop ${app_version} (${build_number}) to App Store Connect for internal TestFlight QA."
