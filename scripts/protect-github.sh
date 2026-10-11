#!/bin/zsh
# Règles du dépôt GitHub : fusion par squash seulement, workflows en lecture seule, approbation des workflows des
# contributeurs extérieurs, signalement privé des failles, et protection de main (pull request, approbation du
# mainteneur, vérifications vertes, historique linéaire, ni suppression ni réécriture).
#   scripts/protect-github.sh [propriétaire/dépôt]
# À relancer après le passage en public : l'offre gratuite de GitHub ne protège les branches que des dépôts publics.
set -uo pipefail
repo=${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
result=0
step() {
  local label="$1"; shift
  if output=$("$@" 2>&1); then
    print "ok      $label"
  else
    print "échec   $label : ${output:0:160}"
    result=1
  fi
}

step "fusion par squash seulement, branches supprimées après fusion" \
  gh api -X PATCH "repos/$repo" -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
    -F allow_auto_merge=false -F web_commit_signoff_required=true
step "workflows en lecture seule, sans droit d'approuver" \
  gh api -X PUT "repos/$repo/actions/permissions/workflow" -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=false
step "workflows des contributeurs extérieurs soumis à approbation" \
  gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
step "signalement privé des failles" \
  gh api -X PUT "repos/$repo/private-vulnerability-reporting"

ruleset=$(cat <<'JSON'
{
  "name": "Protection de main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" } ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"] } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "Tests et traductions" },
          { "context": "Secrets et fichiers interdits" },
          { "context": "Signature des commits" } ] } }
  ]
}
JSON
)
# Une erreur de l'API (dépôt privé sur l'offre gratuite) ne doit pas passer pour un identifiant.
if ! existing=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "Protection de main") | .id' 2>/dev/null); then
  existing=""
fi
if [[ -n "$existing" ]]; then
  step "protection de main (mise à jour)" gh api -X PUT "repos/$repo/rulesets/$existing" --input - <<< "$ruleset"
else
  step "protection de main" gh api -X POST "repos/$repo/rulesets" --input - <<< "$ruleset"
fi
exit $result
