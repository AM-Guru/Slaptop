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
  APP_STORE_FEEDBACK_ID
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
    echo "Missing required App Store submission environment value: ${name}" >&2
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
if [[ ! "${APP_STORE_FEEDBACK_ID}" =~ ^FB[0-9]{6,}$ ]]; then
  echo "APP_STORE_FEEDBACK_ID must be FB followed by at least six digits." >&2
  exit 1
fi
[[ "${GITHUB_RUN_NUMBER}" =~ ^[0-9]+$ ]]
[[ "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]]

work_dir="$(mktemp -d "${RUNNER_TEMP%/}/slaptop-app-store-qa.XXXXXX")"
derived_data="${work_dir}/DerivedData"
archive_path="${work_dir}/SlaptopAppStore.xcarchive"
export_path="${work_dir}/export"
keychain_path="${work_dir}/app-store-signing.keychain-db"
development_p12_path="${work_dir}/apple-development.p12"
distribution_p12_path="${work_dir}/apple-distribution.p12"
asc_key_path="${work_dir}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
review_metadata_path="${work_dir}/review-metadata"
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

APP_STORE_FEEDBACK_ID="${APP_STORE_FEEDBACK_ID}" \
  "${GITHUB_WORKSPACE}/Scripts/render-app-store-review-metadata.sh" \
  "${review_metadata_path}"
for path in \
  "${review_metadata_path}/AppStoreSandboxUsage.txt" \
  "${review_metadata_path}/AppStoreReviewNotes.txt"; do
  [[ -s "${path}" ]]
  grep -Fq "${APP_STORE_FEEDBACK_ID}" "${path}"
  if grep -Fq '@APP_STORE_FEEDBACK_ID@' "${path}"; then
    echo "Generated App Store review metadata contains an unresolved placeholder." >&2
    exit 1
  fi
done

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

# Secret files remain mode 0600 inside the private work directory. Build
# products must use normal distributable modes so App Store processing can
# read every file and traverse every directory in the installer payload.
umask 022
cd "${GITHUB_WORKSPACE}"
xcodegen generate

xcodebuild \
  -project Slaptop.xcodeproj \
  -scheme SlaptopAppStore \
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
category="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "${info_plist}")"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "${info_plist}")"
uses_non_exempt_encryption="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "${info_plist}")"
[[ "${bundle_id}" == "guru.am.slaptop" ]]
[[ "${build_number}" == "${GITHUB_RUN_NUMBER}" ]]
[[ "${category}" == "public.app-category.utilities" ]]
[[ "${icon_name}" == "Slaptop-icon" ]]
[[ "${uses_non_exempt_encryption}" == "false" ]]

icon_path="${app_path}/Contents/Resources/${icon_name}.icns"
asset_catalog_path="${app_path}/Contents/Resources/Assets.car"
asset_info_path="${work_dir}/asset-info.plist"
asset_dump_path="${work_dir}/asset-info.txt"
[[ -s "${icon_path}" ]]
[[ -s "${asset_catalog_path}" ]]
xcrun assetutil --info "${asset_catalog_path}" \
  | /usr/bin/plutil -convert xml1 -o "${asset_info_path}" -- -
/usr/bin/plutil -p "${asset_info_path}" > "${asset_dump_path}"
if ! /usr/bin/grep -Eq \
  '"RenditionName" => "Slaptop-icon1024x1024_' \
  "${asset_dump_path}"; then
  echo "The App Store build does not contain a 1024x1024 Slaptop app-icon rendition." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "${app_path}"

entitlements_path="${work_dir}/archived-entitlements.plist"
codesign -d --entitlements :- "${app_path}" > "${entitlements_path}" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "${entitlements_path}")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.iokit-user-client-class:0' "${entitlements_path}")" == "IOHIDLibUserClient" ]]
if /usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.temporary-exception.iokit-user-client-class:1' \
  "${entitlements_path}" >/dev/null 2>&1; then
  echo "The App Store target contains an unexpected additional IOKit exception." >&2
  exit 1
fi

[[ ! -e "${app_path}/Contents/Resources/SlaptopSensorDaemon" ]]
[[ ! -e "${app_path}/Contents/Library/LaunchDaemons" ]]
[[ -r "${app_path}/Contents/Resources/LICENSE" ]]
[[ -r "${app_path}/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]

if strings "${app_path}/Contents/MacOS/Slaptop" \
  | grep -Fq 'api.github.com/repos/AM-Guru/Slaptop/releases/latest'; then
  echo "The App Store binary unexpectedly contains the GitHub updater." >&2
  exit 1
fi

permission_failures="$(find "${app_path}" \( \
  -type f ! -perm -004 -o \
  -type d ! -perm -005 \
\) -print)"
if [[ -n "${permission_failures}" ]]; then
  echo "The archived app contains paths that App Store processing cannot read:" >&2
  echo "${permission_failures}" >&2
  exit 1
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

echo "Uploaded Slaptop ${app_version} (${build_number}) to App Store Connect for TestFlight QA and App Store review."
