#!/bin/bash

set -euo pipefail
umask 077

readonly EXPECTED_REPOSITORY="AM-Guru/Slaptop"
readonly EXPECTED_REF="refs/heads/main"
readonly EXPECTED_TEAM_ID="59A594LZGR"
readonly EXPECTED_DEVELOPER_ID="Developer ID Application: AM Guru, LLC (59A594LZGR)"
readonly EXPECTED_APP_STORE_DEVELOPMENT="Apple Development: Created via API (AHG2S22W82)"
readonly EXPECTED_APP_STORE_DISTRIBUTION="Apple Distribution: AM Guru, LLC (59A594LZGR)"
readonly EXPECTED_APP_BUNDLE_ID="guru.am.slaptop"
readonly EXPECTED_HELPER_BUNDLE_ID="guru.am.slaptop.sensor-daemon"
readonly EXPECTED_TEST_BUNDLE_ID="guru.am.slaptop.tests"

fail() {
  echo "Release configuration validation failed: $1" >&2
  exit 1
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "missing ${name}"
}

expect_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${label} is not the protected release value"
}

plist_value() {
  local key="$1"
  local path="$2"
  /usr/bin/plutil -extract "${key}" raw -o - "${path}" 2>/dev/null \
    || fail "could not read ${key} from ${path}"
}

resolved_setting() {
  local settings_path="$1"
  local key="$2"
  /usr/bin/plutil -extract "0.buildSettings.${key}" raw -o - "${settings_path}" 2>/dev/null \
    || fail "generated target is missing ${key}"
}

for name in \
  GITHUB_ACTIONS \
  GITHUB_EVENT_NAME \
  GITHUB_REPOSITORY \
  GITHUB_REF \
  GITHUB_REF_NAME \
  GITHUB_REF_TYPE \
  GITHUB_SHA \
  GITHUB_WORKSPACE \
  RUNNER_TEMP \
  APPLE_TEAM_ID \
  DEVELOPER_ID_APPLICATION \
  DEVELOPER_ID_P12_BASE64 \
  DEVELOPER_ID_P12_PASSWORD \
  APP_STORE_DEVELOPMENT \
  APP_STORE_DEVELOPMENT_P12_BASE64 \
  APP_STORE_DEVELOPMENT_P12_PASSWORD \
  APP_STORE_DISTRIBUTION \
  APP_STORE_DISTRIBUTION_P12_BASE64 \
  APP_STORE_DISTRIBUTION_P12_PASSWORD \
  APP_STORE_CONNECT_PRIVATE_KEY_BASE64 \
  APP_STORE_CONNECT_KEY_ID \
  APP_STORE_CONNECT_ISSUER_ID; do
  require_value "${name}"
done

expect_equal "GitHub Actions context" "${GITHUB_ACTIONS}" "true"
expect_equal "event" "${GITHUB_EVENT_NAME}" "push"
expect_equal "repository" "${GITHUB_REPOSITORY}" "${EXPECTED_REPOSITORY}"
expect_equal "ref" "${GITHUB_REF}" "${EXPECTED_REF}"
expect_equal "ref name" "${GITHUB_REF_NAME}" "main"
expect_equal "ref type" "${GITHUB_REF_TYPE}" "branch"
expect_equal "Apple team" "${APPLE_TEAM_ID}" "${EXPECTED_TEAM_ID}"
expect_equal "Developer ID identity" "${DEVELOPER_ID_APPLICATION}" "${EXPECTED_DEVELOPER_ID}"
expect_equal \
  "App Store development identity" \
  "${APP_STORE_DEVELOPMENT}" \
  "${EXPECTED_APP_STORE_DEVELOPMENT}"
expect_equal \
  "App Store distribution identity" \
  "${APP_STORE_DISTRIBUTION}" \
  "${EXPECTED_APP_STORE_DISTRIBUTION}"

[[ "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA is not a full commit SHA"
[[ -z "${GITHUB_HEAD_REF:-}" ]] || fail "pull-request head refs may not use the release runner"
[[ -z "${GITHUB_BASE_REF:-}" ]] || fail "pull-request base refs may not use the release runner"
[[ "$(git -C "${GITHUB_WORKSPACE}" rev-parse HEAD)" == "${GITHUB_SHA}" ]] \
  || fail "checked-out commit does not match GITHUB_SHA"
if git -C "${GITHUB_WORKSPACE}" show-ref --verify --quiet refs/remotes/origin/main; then
  [[ "$(git -C "${GITHUB_WORKSPACE}" rev-parse refs/remotes/origin/main)" == "${GITHUB_SHA}" ]] \
    || fail "checked-out commit is not the fetched origin/main tip"
fi
[[ -z "$(git -C "${GITHUB_WORKSPACE}" status --porcelain --untracked-files=no)" ]] \
  || fail "tracked files changed before release validation"

expect_equal \
  "app Info.plist bundle identifier" \
  "$(plist_value CFBundleIdentifier "${GITHUB_WORKSPACE}/Resources/Slaptop-Info.plist")" \
  "${EXPECTED_APP_BUNDLE_ID}"
expect_equal \
  "launch daemon label" \
  "$(plist_value Label "${GITHUB_WORKSPACE}/Resources/LaunchDaemons/guru.am.slaptop.sensor-daemon.plist")" \
  "${EXPECTED_HELPER_BUNDLE_ID}"
expect_equal \
  "launch daemon associated app" \
  "$(plist_value AssociatedBundleIdentifiers "${GITHUB_WORKSPACE}/Resources/LaunchDaemons/guru.am.slaptop.sensor-daemon.plist")" \
  "${EXPECTED_APP_BUNDLE_ID}"
expect_equal \
  "launch daemon Mach service" \
  "$(/usr/libexec/PlistBuddy -c "Print :MachServices:${EXPECTED_HELPER_BUNDLE_ID}" "${GITHUB_WORKSPACE}/Resources/LaunchDaemons/guru.am.slaptop.sensor-daemon.plist")" \
  "true"
expect_equal \
  "export team" \
  "$(plist_value teamID "${GITHUB_WORKSPACE}/Distribution/ExportOptions.plist")" \
  "${EXPECTED_TEAM_ID}"
expect_equal \
  "notarization export team" \
  "$(plist_value teamID "${GITHUB_WORKSPACE}/Distribution/NotarizeOptions.plist")" \
  "${EXPECTED_TEAM_ID}"
expect_equal \
  "App Store export team" \
  "$(plist_value teamID "${GITHUB_WORKSPACE}/Distribution/AppStoreQAExportOptions.plist")" \
  "${EXPECTED_TEAM_ID}"
expect_equal \
  "App Store export destination" \
  "$(plist_value destination "${GITHUB_WORKSPACE}/Distribution/AppStoreQAExportOptions.plist")" \
  "upload"
expect_equal \
  "App Store export method" \
  "$(plist_value method "${GITHUB_WORKSPACE}/Distribution/AppStoreQAExportOptions.plist")" \
  "app-store-connect"
expect_equal \
  "App Store export signing style" \
  "$(plist_value signingStyle "${GITHUB_WORKSPACE}/Distribution/AppStoreQAExportOptions.plist")" \
  "automatic"
expect_equal \
  "App Store internal-testing restriction" \
  "$(plist_value testFlightInternalTestingOnly "${GITHUB_WORKSPACE}/Distribution/AppStoreQAExportOptions.plist")" \
  "true"

if git -C "${GITHUB_WORKSPACE}" grep -n -E 'com\.kalani' -- \
  project.yml Resources Slaptop Shared SlaptopSensorDaemon 2>/dev/null; then
  fail "repository contains an unapproved legacy bundle ID"
fi

VALIDATION_DIR="$(mktemp -d "${RUNNER_TEMP%/}/slaptop-release-validation.XXXXXX")"
trap 'rm -rf "${VALIDATION_DIR}"' EXIT

xcodegen generate \
  --spec "${GITHUB_WORKSPACE}/project.yml" \
  --project "${VALIDATION_DIR}" \
  --project-root "${GITHUB_WORKSPACE}" \
  --no-env \
  --quiet

for target in Slaptop SlaptopSensorDaemon SlaptopTests; do
  settings_path="${VALIDATION_DIR}/${target}-settings.json"
  xcodebuild \
    -project "${VALIDATION_DIR}/Slaptop.xcodeproj" \
    -target "${target}" \
    -configuration Release \
    -showBuildSettings \
    -json > "${settings_path}"

  expect_equal \
    "${target} development team" \
    "$(resolved_setting "${settings_path}" DEVELOPMENT_TEAM)" \
    "${EXPECTED_TEAM_ID}"
  expect_equal \
    "${target} signing style" \
    "$(resolved_setting "${settings_path}" CODE_SIGN_STYLE)" \
    "Automatic"
  expect_equal \
    "${target} architectures" \
    "$(resolved_setting "${settings_path}" ARCHS)" \
    "arm64"
done

expect_equal \
  "Slaptop bundle identifier" \
  "$(resolved_setting "${VALIDATION_DIR}/Slaptop-settings.json" PRODUCT_BUNDLE_IDENTIFIER)" \
  "${EXPECTED_APP_BUNDLE_ID}"
expect_equal \
  "sensor helper bundle identifier" \
  "$(resolved_setting "${VALIDATION_DIR}/SlaptopSensorDaemon-settings.json" PRODUCT_BUNDLE_IDENTIFIER)" \
  "${EXPECTED_HELPER_BUNDLE_ID}"
expect_equal \
  "test bundle identifier" \
  "$(resolved_setting "${VALIDATION_DIR}/SlaptopTests-settings.json" PRODUCT_BUNDLE_IDENTIFIER)" \
  "${EXPECTED_TEST_BUNDLE_ID}"
expect_equal \
  "Slaptop hardened runtime" \
  "$(resolved_setting "${VALIDATION_DIR}/Slaptop-settings.json" ENABLE_HARDENED_RUNTIME)" \
  "YES"
expect_equal \
  "sensor helper hardened runtime" \
  "$(resolved_setting "${VALIDATION_DIR}/SlaptopSensorDaemon-settings.json" ENABLE_HARDENED_RUNTIME)" \
  "YES"

printf '%s' "${DEVELOPER_ID_P12_BASE64}" | /usr/bin/base64 -D > "${VALIDATION_DIR}/developer-id.p12" \
  || fail "Developer ID PKCS#12 is not valid base64"
P12_VALIDATION_PASSWORD="${DEVELOPER_ID_P12_PASSWORD}" \
  /usr/bin/openssl pkcs12 \
    -in "${VALIDATION_DIR}/developer-id.p12" \
    -passin env:P12_VALIDATION_PASSWORD \
    -clcerts \
    -nokeys \
    -out "${VALIDATION_DIR}/developer-id-cert.pem" >/dev/null 2>&1 \
  || fail "Developer ID PKCS#12 or its password is invalid"
certificate_subject="$(
  /usr/bin/openssl x509 \
    -in "${VALIDATION_DIR}/developer-id-cert.pem" \
    -noout \
    -subject
)"
[[ "${certificate_subject}" == *"${EXPECTED_DEVELOPER_ID}"* ]] \
  || fail "Developer ID certificate common name is not the protected identity"
[[ "${certificate_subject}" =~ OU[[:space:]]*=[[:space:]]*${EXPECTED_TEAM_ID} ]] \
  || fail "Developer ID certificate team does not match the protected team"

printf '%s' "${APP_STORE_DEVELOPMENT_P12_BASE64}" | /usr/bin/base64 -D \
  > "${VALIDATION_DIR}/apple-development.p12" \
  || fail "Apple Development PKCS#12 is not valid base64"
P12_VALIDATION_PASSWORD="${APP_STORE_DEVELOPMENT_P12_PASSWORD}" \
  /usr/bin/openssl pkcs12 \
    -in "${VALIDATION_DIR}/apple-development.p12" \
    -passin env:P12_VALIDATION_PASSWORD \
    -clcerts \
    -nokeys \
    -out "${VALIDATION_DIR}/apple-development-cert.pem" >/dev/null 2>&1 \
  || fail "Apple Development PKCS#12 or its password is invalid"
development_subject="$(
  /usr/bin/openssl x509 \
    -in "${VALIDATION_DIR}/apple-development-cert.pem" \
    -noout \
    -subject
)"
[[ "${development_subject}" == *"${EXPECTED_APP_STORE_DEVELOPMENT}"* ]] \
  || fail "Apple Development certificate common name is not the protected identity"
[[ "${development_subject}" =~ OU[[:space:]]*=[[:space:]]*${EXPECTED_TEAM_ID} ]] \
  || fail "Apple Development certificate team does not match the protected team"
P12_VALIDATION_PASSWORD="${APP_STORE_DEVELOPMENT_P12_PASSWORD}" \
  /usr/bin/openssl pkcs12 \
    -in "${VALIDATION_DIR}/apple-development.p12" \
    -passin env:P12_VALIDATION_PASSWORD \
    -nocerts \
    -nodes \
    -out "${VALIDATION_DIR}/apple-development-key.pem" >/dev/null 2>&1 \
  || fail "Apple Development PKCS#12 does not contain an accessible private key"
/usr/bin/openssl pkey \
  -in "${VALIDATION_DIR}/apple-development-key.pem" \
  -noout >/dev/null 2>&1 \
  || fail "Apple Development PKCS#12 private key is invalid"

printf '%s' "${APP_STORE_DISTRIBUTION_P12_BASE64}" | /usr/bin/base64 -D \
  > "${VALIDATION_DIR}/apple-distribution.p12" \
  || fail "Apple Distribution PKCS#12 is not valid base64"
P12_VALIDATION_PASSWORD="${APP_STORE_DISTRIBUTION_P12_PASSWORD}" \
  /usr/bin/openssl pkcs12 \
    -in "${VALIDATION_DIR}/apple-distribution.p12" \
    -passin env:P12_VALIDATION_PASSWORD \
    -clcerts \
    -nokeys \
    -out "${VALIDATION_DIR}/apple-distribution-cert.pem" >/dev/null 2>&1 \
  || fail "Apple Distribution PKCS#12 or its password is invalid"
distribution_subject="$(
  /usr/bin/openssl x509 \
    -in "${VALIDATION_DIR}/apple-distribution-cert.pem" \
    -noout \
    -subject
)"
[[ "${distribution_subject}" == *"${EXPECTED_APP_STORE_DISTRIBUTION}"* ]] \
  || fail "Apple Distribution certificate common name is not the protected identity"
[[ "${distribution_subject}" =~ OU[[:space:]]*=[[:space:]]*${EXPECTED_TEAM_ID} ]] \
  || fail "Apple Distribution certificate team does not match the protected team"
P12_VALIDATION_PASSWORD="${APP_STORE_DISTRIBUTION_P12_PASSWORD}" \
  /usr/bin/openssl pkcs12 \
    -in "${VALIDATION_DIR}/apple-distribution.p12" \
    -passin env:P12_VALIDATION_PASSWORD \
    -nocerts \
    -nodes \
    -out "${VALIDATION_DIR}/apple-distribution-key.pem" >/dev/null 2>&1 \
  || fail "Apple Distribution PKCS#12 does not contain an accessible private key"
/usr/bin/openssl pkey \
  -in "${VALIDATION_DIR}/apple-distribution-key.pem" \
  -noout >/dev/null 2>&1 \
  || fail "Apple Distribution PKCS#12 private key is invalid"

printf '%s' "${APP_STORE_CONNECT_PRIVATE_KEY_BASE64}" | /usr/bin/base64 -D \
  > "${VALIDATION_DIR}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8" \
  || fail "App Store Connect key is not valid base64"
/usr/bin/openssl pkey \
  -in "${VALIDATION_DIR}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8" \
  -noout >/dev/null 2>&1 \
  || fail "App Store Connect private key is invalid"
[[ "${APP_STORE_CONNECT_KEY_ID}" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "App Store Connect key ID has an unexpected format"
[[ "${APP_STORE_CONNECT_ISSUER_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || fail "App Store Connect issuer ID has an unexpected format"

echo "Release repository, ref, bundle IDs, team, certificates, and notarization key are valid."
