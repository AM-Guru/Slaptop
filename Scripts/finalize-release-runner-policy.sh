#!/bin/bash

set -euo pipefail

readonly REPOSITORY="AM-Guru/Slaptop"
readonly OWNER="kalanihelekunihi"
readonly GROUP_NAME="slaptop-main-release"
readonly ENVIRONMENT_NAME="slaptop-release"
readonly WORKFLOW="AM-Guru/Slaptop/.github/workflows/release.yml@refs/heads/main"
readonly INDEPENDENT_RELEASE_REVIEWER="${INDEPENDENT_RELEASE_REVIEWER:-}"

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

requested_independent_reviewer="${INDEPENDENT_RELEASE_REVIEWER}"

independent_reviewer=""
required_reviews_json='null'
independent_review_required=false
if [[ -n "${requested_independent_reviewer}" ]]; then
  [[ "${requested_independent_reviewer}" != "${OWNER}" ]] \
    || fail "INDEPENDENT_RELEASE_REVIEWER must name someone other than ${OWNER}"
  reviewer_permission="$({
    gh api "repos/${REPOSITORY}/collaborators/${requested_independent_reviewer}/permission" \
      --jq .permission
  } 2>/dev/null)" \
    || fail "${requested_independent_reviewer} must be a repository collaborator"
  case "${reviewer_permission}" in
    admin|maintain|write) ;;
    *) fail "${requested_independent_reviewer} needs write access to provide a required review" ;;
  esac
  independent_reviewer="${requested_independent_reviewer}"
  independent_review_required=true
  required_reviews_json='{
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1,
    "require_last_push_approval": true
  }'
fi

# GitHub refuses workflow restrictions until the exact workflow exists at the
# pinned ref. Keeping public access disabled until this succeeds is intentional.
gh api "repos/${REPOSITORY}/contents/.github/workflows/release.yml?ref=main" >/dev/null \
  || fail "merge the reviewed release workflow to main before finalizing the runner group"

repository_id="$(gh api "repos/${REPOSITORY}" --jq .id)"
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

# Establish branch protection from scratch instead of assuming another manual
# step created it. Re-running this call converges the complete rule to the same
# fail-closed state.
gh api --method PUT "repos/${REPOSITORY}/branches/main/protection" --input - >/dev/null <<JSON
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": ${required_reviews_json},
  "restrictions": {
    "users": ["${OWNER}"],
    "teams": [],
    "apps": []
  },
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
gh api --method POST "repos/${REPOSITORY}/branches/main/protection/required_signatures" >/dev/null

gh api --method PUT "repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}" \
  --input - >/dev/null <<'JSON'
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "can_admins_bypass": false,
  "reviewers": [],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
JSON

deployment_policy_endpoint="repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}/deployment-branch-policies"
while IFS= read -r policy_id; do
  [[ -n "${policy_id}" ]] || continue
  gh api --method DELETE "${deployment_policy_endpoint}/${policy_id}" >/dev/null
done < <(gh api "${deployment_policy_endpoint}" --jq '.branch_policies[].id')
gh api --method POST "${deployment_policy_endpoint}" \
  -f name='main' \
  -f type='branch' >/dev/null

# Secret scanning and push protection are available for this public repository
# and must remain enabled for every subsequent run of the finalizer.
gh api --method PATCH "repos/${REPOSITORY}" --input - >/dev/null <<'JSON'
{
  "security_and_analysis": {
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"}
  }
}
JSON

gh api --method PUT "repos/${REPOSITORY}/actions/permissions" \
  -F enabled=true \
  -f allowed_actions='selected' \
  -F sha_pinning_required=true >/dev/null
gh api --method PUT "repos/${REPOSITORY}/actions/permissions/selected-actions" \
  -F github_owned_allowed=true \
  -F verified_allowed=false >/dev/null

unexpected_push_collaborators="$(
  gh api "repos/${REPOSITORY}/collaborators" --paginate \
    --jq ".[] | select(.login != \"${OWNER}\" and .login != \"${independent_reviewer}\" and .permissions.push == true) | .login"
)"
[[ -z "${unexpected_push_collaborators}" ]] \
  || fail "unexpected push-capable collaborators: ${unexpected_push_collaborators}"

protection_endpoint="repos/${REPOSITORY}/branches/main/protection"
expect_api_value "${protection_endpoint}" '.restrictions.users | length' '1' 'restricted pusher count'
expect_api_value "${protection_endpoint}" '.restrictions.users[0].login' "${OWNER}" 'restricted pusher'
if [[ "${independent_review_required}" == true ]]; then
  expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.required_approving_review_count' '1' 'required approvals'
  expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.require_code_owner_reviews' 'false' 'Code Owner review requirement'
  expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.dismiss_stale_reviews' 'true' 'stale review dismissal'
  expect_api_value "${protection_endpoint}" '.required_pull_request_reviews.require_last_push_approval' 'true' 'last-push approval requirement'
else
  expect_api_value "${protection_endpoint}" '.required_pull_request_reviews == null' 'true' 'single-maintainer review policy'
fi
expect_api_value "${protection_endpoint}" '.enforce_admins.enabled' 'true' 'administrator enforcement'
expect_api_value "${protection_endpoint}" '.required_signatures.enabled' 'true' 'signed commit requirement'
expect_api_value "${protection_endpoint}" '.required_linear_history.enabled' 'true' 'linear-history requirement'
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
expect_api_value \
  "repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}" \
  '.deployment_branch_policy.protected_branches' \
  'false' \
  'release environment protected-branch policy'
expect_api_value \
  "repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}" \
  '.deployment_branch_policy.custom_branch_policies' \
  'true' \
  'release environment custom-branch policy'
expect_api_value \
  "repos/${REPOSITORY}/environments/${ENVIRONMENT_NAME}" \
  '[.protection_rules[] | select(.type == "required_reviewers")] | length' \
  '0' \
  'release environment required-reviewer count'
expect_api_value "${deployment_policy_endpoint}" '.total_count' '1' 'release branch-policy count'
expect_api_value "${deployment_policy_endpoint}" '.branch_policies[0].name' 'main' 'release branch policy'

expect_api_value "repos/${REPOSITORY}" '.security_and_analysis.secret_scanning.status' 'enabled' 'secret scanning'
expect_api_value "repos/${REPOSITORY}" '.security_and_analysis.secret_scanning_push_protection.status' 'enabled' 'secret push protection'

codeowners="$(
  gh api "repos/${REPOSITORY}/contents/.github/CODEOWNERS?ref=main" --jq .content \
    | tr -d '\n' \
    | /usr/bin/base64 -D
)"
[[ "${codeowners}" == *"* @${OWNER}"* ]] \
  || fail "main does not assign the repository to @${OWNER} in CODEOWNERS"

echo "GitHub main protection, automatic release environment, secret scanning, Actions, and runner policies are enforced."
