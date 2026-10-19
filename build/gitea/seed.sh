#!/bin/sh
# Isoloom `setup` step for the Gitea machine (runs once, after Gitea is healthy, in the Gitea image,
# sharing its network namespace so Gitea is reachable at 127.0.0.1:3000). It provisions Wonderland's
# mock-turtle repository over the Gitea API, pushes the baked sample project, then PROTECTS main so
# the auto-merge bot is the only way onto it:
#   - org `Wonderland`, a private repo `mock-turtle`
#   - `alice`          (the attacker) with WRITE access   -> used by the player / the solver
#   - `mock-turtle-ci` (the auto-merge bot) with WRITE     -> the ONLY user allowed to push/merge main
#   - `jenkins`        with READ access                    -> used by Jenkins to poll the repo
#   - branch protection on `main`: push + merge restricted to `mock-turtle-ci`, so alice can open a
#     pull request but can neither push to main nor merge it herself — only the bot can.
# No challenge secret is handled here; the flag is a Jenkins credential injected elsewhere.
set -eu

BASE="${GITEA_BASE_URL:-http://127.0.0.1:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-wonderland_admin}"
ADMIN_PASS="${GITEA_ADMIN_PASS:-W0nderland-admin}"
ORG="Wonderland"
REPO="mock-turtle"
SRC="${MT_SRC:-/opt/mock-turtle-src}"

ATTACKER_USER="alice"
ATTACKER_PASS="alice"
BOT_USER="mock-turtle-ci"
BOT_PASS="mock-turtle-ci"
CI_USER="jenkins"
CI_PASS="jenkins"

AUTH="$ADMIN_USER:$ADMIN_PASS"
API="$BASE/api/v1"

log() { echo "seed: $1"; }

# POST/PUT JSON as admin; tolerate 'already exists' (409/422) so the job is idempotent on restart.
api() {  # method path json
  if [ -n "${3:-}" ]; then
    code=$(curl -s -o /tmp/seed.out -w '%{http_code}' -X "$1" \
           -H 'Content-Type: application/json' -u "$AUTH" \
           --data "$3" "$API$2" 2>/dev/null || echo 000)
  else
    code=$(curl -s -o /tmp/seed.out -w '%{http_code}' -X "$1" -u "$AUTH" "$API$2" 2>/dev/null || echo 000)
  fi
  case "$code" in
    2*) return 0 ;;
    409|422) log "exists ($code): $1 $2"; return 0 ;;
    *) log "WARN $code: $1 $2 -> $(tr -d '\n' < /tmp/seed.out | cut -c1-200)"; return 1 ;;
  esac
}

# 1. Wait for the Gitea API.
i=0
while :; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$API/version" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && break
  i=$((i+1)); [ "$i" -lt 120 ] || { log "FATAL: Gitea API never answered"; exit 1; }
  sleep 2
done
log "Gitea API is up"

# 2. Idempotency: if the repo already has a main branch, everything below is already done.
c=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$API/repos/$ORG/$REPO/branches/main" 2>/dev/null || echo 000)
if [ "$c" = "200" ]; then
  log "mock-turtle already seeded; nothing to do"
  exit 0
fi

# 3. Org, users, repository.
api POST "/orgs" "{\"username\":\"$ORG\",\"visibility\":\"private\"}"
api POST "/admin/users" "{\"username\":\"$ATTACKER_USER\",\"email\":\"alice@wonderland.example\",\"password\":\"$ATTACKER_PASS\",\"must_change_password\":false}"
api POST "/admin/users" "{\"username\":\"$BOT_USER\",\"email\":\"mock-turtle-ci@wonderland.example\",\"password\":\"$BOT_PASS\",\"must_change_password\":false}"
api POST "/admin/users" "{\"username\":\"$CI_USER\",\"email\":\"jenkins@wonderland.example\",\"password\":\"$CI_PASS\",\"must_change_password\":false}"
api POST "/orgs/$ORG/repos" "{\"name\":\"$REPO\",\"private\":true,\"auto_init\":false,\"default_branch\":\"main\"}"

# 4. Access: alice writes (the attacker), mock-turtle-ci writes (the bot), jenkins reads (the poller).
api PUT "/repos/$ORG/$REPO/collaborators/$ATTACKER_USER" "{\"permission\":\"write\"}"
api PUT "/repos/$ORG/$REPO/collaborators/$BOT_USER" "{\"permission\":\"write\"}"
api PUT "/repos/$ORG/$REPO/collaborators/$CI_USER" "{\"permission\":\"read\"}"

# 5. Push the baked sample project (the real Jenkinsfile + version live here) to main, BEFORE main is
#    protected (so this initial import is allowed). The `version` file is written without a trailing
#    newline on purpose: the bot's structure check requires it (see automerge.sh).
WORK="$(mktemp -d)"
cp -a "$SRC/." "$WORK/"
cd "$WORK"
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Wonderland Admin" GIT_AUTHOR_EMAIL="admin@wonderland.example"
export GIT_COMMITTER_NAME="Wonderland Admin" GIT_COMMITTER_EMAIL="admin@wonderland.example"
export GIT_AUTHOR_DATE="2024-02-01T09:00:00" GIT_COMMITTER_DATE="2024-02-01T09:00:00"
git -c init.defaultBranch=main init -q
git add -A
git commit -q -m "Initial import of the mockturtle package, version file and CI pipeline"
PUSH_URL="http://$ADMIN_USER:$ADMIN_PASS@127.0.0.1:3000/$ORG/$REPO.git"
git push -q "$PUSH_URL" main
cd /
rm -rf "$WORK"

# 6. Protect main: restrict BOTH direct push and pull-request merge to the bot only. alice can open
#    pull requests but cannot push to main or merge them — the auto-merge bot is the only path onto
#    main. No required approvals / status checks, so the bot can merge a passing pull request at once.
api POST "/repos/$ORG/$REPO/branch_protections" "{\"branch_name\":\"main\",\"enable_push\":true,\"enable_push_whitelist\":true,\"push_whitelist_usernames\":[\"$BOT_USER\"],\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$BOT_USER\"],\"required_approvals\":0,\"enable_status_check\":false,\"block_on_official_review_requests\":false,\"block_on_outdated_branch\":false,\"dismiss_stale_approvals\":false,\"require_signed_commits\":false}"

log "mock-turtle seeded: private repo with main (protected, bot-only), alice=write, mock-turtle-ci=write(bot), jenkins=read"
