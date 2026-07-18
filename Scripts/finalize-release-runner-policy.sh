#!/bin/bash

set -euo pipefail

readonly REPOSITORY="AM-Guru/Slaptop"
readonly OWNER="kalanihelekunihi"
readonly GROUP_NAME="slaptop-main-release"
readonly ENVIRONMENT_NAME="slaptop-release"
readonly WORKFLOW="AM-Guru/Slaptop/.github/workflows/release.yml@refs/heads/main"

fail() {
  echo "GitHub release policy configuration failed: $1" >&2
  exit 1
}

expect_api_value() {
  local endpoint="$1"
  local query="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(gh api "${endpoint}" --jq "${query}")"
  [[ "${actual}" == "${expected}" ]] || fail "${label} is ${actual:-<missing>}, expected ${expected}"
}

command -v gh >/dev/null || fail "gh is required"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
[[ "$(gh api user --jq .login)" == "${OWNER}" ]] \
  || fail "authenticate gh as ${OWNER}"
[[ "$(gh repo view "${REPOSITORY}" --json viewerPermission --jq .viewerPermission)" == "ADMIN" ]] \
  || fail "${OWNER} needs repository admin access"

# GitHub refuses workflow restrictions until the exact workflow exists at the
# pinned ref. Keeping public access disabled until this succeeds is intentional.
gh api "repos/${REPOSITORY}/contents/.github/workflows/release.yml?ref=main" >/dev/null \
  || fail "merge the reviewed release workflow to main before finalizing the runner group"

repository_id="$(gh api "repos/${REPOSITORY}" --jq .id)"
owner_id="$(gh api "users/${OWNER}" --jq .id)"
group_id="$(
  gh api orgs/AM-Guru/actions/runner-groups \
    --jq ".runner_groups[] | select(.name == \"${GROUP_NAME}\") | .id"
)"
[[ -n "${group_id}" ]] || fail "runner group ${GROUP_NAME} does not exist"

gh api --method PATCH "orgs/AM-Guru/actions/runner-groups/${group_id}" \
  -f name="${GROUP_NAME}" \
  -f visibility='selected' \
  -F allows_public_repositories=true \
  -F restricted_to_workflows=true \
  -f "selected_workflows[]=${WORKFLOW}" >/dev/null
gh api --method PUT \
  "orgs/AM-Guru/actions/runner-groups/${group_id}/repositories/${repository_id}" >/dev/null

gh api --method PUT "repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}" \
  -F wait_timer=0 \
  -F prevent_self_review=false \
  -F can_admins_bypass=false \
  -f 'reviewers[][type]=User' \
  -F "reviewers[][id]=${owner_id}" \
  -F 'deployment_branch_policy[protected_branches]=true' \
  -F 'deployment_branch_policy[custom_branch_policies]=false' >/dev/null

gh api --method PUT "repos/${REPOSITORY}/actions/permissions" \
  -F enabled=true \
  -f allowed_actions='selected' \
  -F sha_pinning_required=true >/dev/null
gh api --method PUT "repos/${REPOSITORY}/actions/permissions/selected-actions" \
  -F github_owned_allowed=true \
  -F verified_allowed=false >/dev/null
gh api --method POST "repos/${REPOSITORY}/branches/main/protection/required_signatures" >/dev/null

unexpected_push_collaborators="$(
  gh api "repos/${REPOSITORY}/collaborators" --paginate \
    --jq ".[] | select(.login != \"${OWNER}\" and .permissions.push == true) | .login"
)"
[[ -z "${unexpected_push_collaborators}" ]] \
  || fail "unexpected push-capable collaborators: ${unexpected_push_collaborators}"

protection_endpoint="repos/${REPOSITORY}/branches/main/protection"
expect_api_value "${protection_endpoint}" '.restrictions.users | length' '1' 'restricted pusher count'
expect_api_value "${protection_endpoint}" '.restrictions.users[0].login' "${OWNER}" 'restricted pusher'
expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.required_approving_review_count' '1' 'required approvals'
expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.require_code_owner_reviews' 'true' 'Code Owner review requirement'
expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.dismiss_stale_reviews' 'true' 'stale review dismissal'
expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.require_last_push_approval' 'true' 'last-push approval requirement'
expect_api_value "${protection_endpoint}" '.enforce_admins.enabled' 'true' 'administrator enforcement'
expect_api_value "${protection_endpoint}" '.required_signatures.enabled' 'true' 'signed commit requirement'
expect_api_value "${protection_endpoint}" '.required_conversation_resolution.enabled' 'true' 'conversation resolution requirement'
expect_api_value "${protection_endpoint}" '.allow_force_pushes.enabled' 'false' 'force-push setting'
expect_api_value "${protection_endpoint}" '.allow_deletions.enabled' 'false' 'branch deletion setting'

expect_api_value \
  "orgs/AM-Guru/actions/runner-groups/${group_id}" \
  '.visibility' \
  'selected' \
  'runner repository visibility'
expect_api_value \
  "orgs/AM-Guru/actions/runner-groups/${group_id}" \
  '.allows_public_repositories' \
  'true' \
  'runner public-repository access'
expect_api_value \
  "orgs/AM-Guru/actions/runner-groups/${group_id}" \
  '.restricted_to_workflows' \
  'true' \
  'runner workflow restriction'
expect_api_value \
  "orgs/AM-Guru/actions/runner-groups/${group_id}" \
  '.selected_workflows[0]' \
  "${WORKFLOW}" \
  'allowed runner workflow'
expect_api_value \
  "repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}" \
  '.can_admins_bypass' \
  'false' \
  'release environment administrator bypass'

codeowners="$(
  gh api "repos/${REPOSITORY}/contents/.github/CODEOWNERS?ref=main" --jq .content \
    | tr -d '\n' \
    | /usr/bin/base64 -D
)"
[[ "${codeowners}" == *"* @${OWNER}"* ]] \
  || fail "main does not assign the repository to @${OWNER} in CODEOWNERS"

echo "GitHub main protection, release approval, Actions, and runner policies are enforced."
