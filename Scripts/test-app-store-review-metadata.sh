#!/bin/bash

set -euo pipefail
umask 077

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slaptop-review-metadata-test.XXXXXX")"
readonly TEST_DIR

cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

valid_output="${TEST_DIR}/valid"
APP_STORE_FEEDBACK_ID=FB12345678 \
  "${REPOSITORY_ROOT}/Scripts/render-app-store-review-metadata.sh" \
  "${valid_output}" >/dev/null

for path in \
  "${valid_output}/AppStoreSandboxUsage.txt" \
  "${valid_output}/AppStoreReviewNotes.txt"; do
  [[ -s "${path}" ]]
  grep -Fq 'FB12345678' "${path}"
  if grep -Fq '@APP_STORE_FEEDBACK_ID@' "${path}"; then
    echo "Unresolved Feedback Assistant placeholder in ${path}" >&2
    exit 1
  fi
done

for invalid_id in FB12345 FB123ABC 12345678; do
  if APP_STORE_FEEDBACK_ID="${invalid_id}" \
    "${REPOSITORY_ROOT}/Scripts/render-app-store-review-metadata.sh" \
    "${TEST_DIR}/invalid-${invalid_id}" >/dev/null 2>&1; then
    echo "Renderer accepted invalid Feedback Assistant ID: ${invalid_id}" >&2
    exit 1
  fi
done

if APP_STORE_FEEDBACK_ID='' \
  "${REPOSITORY_ROOT}/Scripts/render-app-store-review-metadata.sh" \
  "${TEST_DIR}/invalid-empty" >/dev/null 2>&1; then
  echo "Renderer accepted an empty Feedback Assistant ID" >&2
  exit 1
fi

echo "App Store review metadata tests passed."
