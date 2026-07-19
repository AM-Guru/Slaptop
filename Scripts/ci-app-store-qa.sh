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
  APP_STORE_DEVELOPMENT
  APP_STORE_DEVELOPMENT_P12_BASE64
  APP_STORE_DEVELOPMENT_P12_PASSWORD
  APP_STORE_DISTRIBUTION
  APP_STORE_DISTRIBUTION_P12_BASE64
  APP_STORE_DISTRIBUTION_P12_PASSWORD
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
[[ "${APP_STORE_DEVELOPMENT}" == "Apple Development: Created via API (AHG2S22W82)" ]]
[[ "${APP_STORE_DISTRIBUTION}" == "Apple Distribution: AM Guru, LLC (${APPLE_TEAM_ID})" ]]
[[ "${GITHUB_RUN_NUMBER}" =~ ^[0-9]+$ ]]
[[ "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]]

work_dir="$(mktemp -d "${RUNNER_TEMP%/}/slaptop-app-store-qa.XXXXXX")"
derived_data="${work_dir}/DerivedData"
archive_path="${work_dir}/Slaptop.xcarchive"
export_path="${work_dir}/export"
keychain_path="${work_dir}/app-store-signing.keychain-db"
development_p12_path="${work_dir}/apple-development.p12"
distribution_p12_path="${work_dir}/apple-distribution.p12"
asc_key_path="${work_dir}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
keychain_password="$(openssl rand -hex 32)"
original_keychains=()

while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  keychain="${keychain%\"*}"
  [[ -n "${keychain}" ]] && original_keychains+=("${keychain}")
done < <(security list-keychains -d user)

cleanup() {
  local exit_code=$?
  set +e
  if ((${#original_keychains[@]})); then
    security list-keychains -d user -s "${original_keychains[@]}"
  fi
  security delete-keychain "${keychain_path}" >/dev/null 2>&1
  rm -rf "${work_dir}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "${APP_STORE_DEVELOPMENT_P12_BASE64}" | /usr/bin/base64 -D > "${development_p12_path}"
printf '%s' "${APP_STORE_DISTRIBUTION_P12_BASE64}" | /usr/bin/base64 -D > "${distribution_p12_path}"
printf '%s' "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64}" | /usr/bin/base64 -D > "${asc_key_path}"
chmod 600 "${development_p12_path}" "${distribution_p12_path}" "${asc_key_path}"
/usr/bin/openssl pkey -in "${asc_key_path}" -noout >/dev/null

security create-keychain -p "${keychain_password}" "${keychain_path}"
security set-keychain-settings -lut 21600 "${keychain_path}"
security unlock-keychain -p "${keychain_password}" "${keychain_path}"
security import "${development_p12_path}" \
  -k "${keychain_path}" \
  -P "${APP_STORE_DEVELOPMENT_P12_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security import "${distribution_p12_path}" \
  -k "${keychain_path}" \
  -P "${APP_STORE_DISTRIBUTION_P12_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${keychain_password}" \
  "${keychain_path}" >/dev/null
security list-keychains -d user -s "${keychain_path}"

identities="$(security find-identity -v -p codesigning "${keychain_path}")"
for identity in "${APP_STORE_DEVELOPMENT}" "${APP_STORE_DISTRIBUTION}"; do
  if ! grep -Fq "\"${identity}\"" <<< "${identities}"; then
    echo "The imported PKCS#12 files do not contain ${identity}." >&2
    exit 1
  fi
done

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
