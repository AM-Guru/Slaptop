#!/bin/bash

set -euo pipefail
umask 022

readonly OUTPUT_DIR="${1:-}"
readonly FEEDBACK_ID="${APP_STORE_FEEDBACK_ID:-}"
readonly TOKEN='@APP_STORE_FEEDBACK_ID@'
readonly MAX_FIELD_CHARACTERS=4000

fail() {
  echo "App Store review metadata generation failed: $1" >&2
  exit 1
}

if [[ -z "${OUTPUT_DIR}" ]]; then
  fail "usage: APP_STORE_FEEDBACK_ID=FB12345678 $0 OUTPUT_DIRECTORY"
fi

if [[ ! "${FEEDBACK_ID}" =~ ^FB[0-9]{6,}$ ]]; then
  fail "APP_STORE_FEEDBACK_ID must be FB followed by at least six digits"
fi

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

render_template() {
  local template_path="$1"
  local output_path="$2"
  local character_count

  [[ -f "${template_path}" ]] || fail "missing template ${template_path}"
  grep -Fq "${TOKEN}" "${template_path}" \
    || fail "template ${template_path} does not contain ${TOKEN}"

  /usr/bin/sed "s/${TOKEN}/${FEEDBACK_ID}/g" "${template_path}" > "${output_path}"

  if grep -Fq "${TOKEN}" "${output_path}"; then
    fail "unresolved placeholder in ${output_path}"
  fi
  grep -Fq "${FEEDBACK_ID}" "${output_path}" \
    || fail "Feedback Assistant case is absent from ${output_path}"

  character_count="$(/usr/bin/wc -m < "${output_path}" | tr -d '[:space:]')"
  if ((character_count > MAX_FIELD_CHARACTERS)); then
    fail "${output_path} exceeds ${MAX_FIELD_CHARACTERS} characters"
  fi
}

/bin/mkdir -p "${OUTPUT_DIR}"
render_template \
  "${REPOSITORY_ROOT}/Distribution/AppStoreSandboxUsage.template.txt" \
  "${OUTPUT_DIR}/AppStoreSandboxUsage.txt"
render_template \
  "${REPOSITORY_ROOT}/Distribution/AppStoreReviewNotes.template.txt" \
  "${OUTPUT_DIR}/AppStoreReviewNotes.txt"

echo "Generated App Store review metadata for ${FEEDBACK_ID}:"
echo "  ${OUTPUT_DIR}/AppStoreSandboxUsage.txt"
echo "  ${OUTPUT_DIR}/AppStoreReviewNotes.txt"
