#!/bin/bash
# mock-turtle-automerge: Wonderland's auto-merge bot (CICD-SEC-1, Insufficient Flow Control).
#
# Run once a minute by the `mock-turtle-automerge` Jenkins pipeline, with the bot's Gitea write
# credential bound as $MT_USER / $MT_PASS. It lists the open pull requests targeting main and merges
# each one whose change looks like a harmless version bump. The merge rule is the upstream CI/CD Goat
# "Mock Turtle" rule, reproduced exactly — three naive checks:
#
#   check1  the pull request adds NO NET words: (added words) - (removed words) == 0, measured with
#           `git diff --word-diff=porcelain origin/main` (a pure version bump removes one word, the
#           old version, and adds one, the new version, so a tidy bump is net zero).
#   check2  the `version` file keeps its dotted structure: it is a single line (no trailing newline,
#           so `wc -l` is 0) and matches ^\d{1,2}\.\d{1,2}\.\d{1,2}$.
#   check3  the `version` file is among the changed files.
#
# None of this verifies WHICH other files changed or WHAT was added — so an attacker can append a
# payload to the Jenkinsfile and delete an equal number of words elsewhere (keeping check1 at zero),
# bump the version (check2, check3), and the bot merges the malicious change onto main.
#
# The merge is performed over the Gitea API as the bot user, which is the only user allowed to merge
# into the protected main branch. The bot never touches the flag; it only moves code onto main.
set -u

GITEA_HOST="${MT_GITEA_HOST:-gitea:3000}"
GITEA="http://${GITEA_HOST}"
ORG="Wonderland"
REPO="mock-turtle"
API="$GITEA/api/v1/repos/$ORG/$REPO"

BOT_USER="${MT_USER:-mock-turtle-ci}"
BOT_PASS="${MT_PASS:-mock-turtle-ci}"
CREDS="$BOT_USER:$BOT_PASS"

log() { echo "automerge: $1" >&2; }

# List open pull requests whose base is main: "<number> <head-ref>" per line.
prs="$(curl -s -m 15 -u "$CREDS" "$API/pulls?state=open&limit=50" 2>/dev/null \
       | jq -r '.[] | select(.base.ref=="main") | "\(.number) \(.head.ref)"' 2>/dev/null)"

if [ -z "$prs" ]; then
  log "no open pull requests to consider"
  exit 0
fi

export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

echo "$prs" | while read -r PR_ID HEAD_REF; do
  [ -n "$PR_ID" ] || continue
  log "considering PR #$PR_ID (head: $HEAD_REF)"

  WORK="$(mktemp -d)"
  REMOTE="http://$CREDS@$GITEA_HOST/$ORG/$REPO.git"
  if ! git clone -q "$REMOTE" "$WORK/repo" 2>/dev/null; then
    log "  could not clone the repository; skipping"
    rm -rf "$WORK"; continue
  fi
  cd "$WORK/repo" || { rm -rf "$WORK"; continue; }

  # Check out the pull request's head so the diff is main -> head.
  if ! git fetch -q origin "$HEAD_REF" 2>/dev/null || ! git checkout -q FETCH_HEAD 2>/dev/null; then
    log "  could not fetch the pull-request head; skipping"
    cd /; rm -rf "$WORK"; continue
  fi

  # check1: no net words added across the whole diff.
  gitp="$(git diff --word-diff=porcelain origin/main | grep -e "^+[^+]" | wc -w | xargs)"
  gitm="$(git diff --word-diff=porcelain origin/main | grep -e "^-[^-]" | wc -w | xargs)"
  if [ "$((gitp - gitm))" -eq 0 ]; then check1=true; else check1=false; fi

  # check2: the version file keeps its dotted structure (single line, no trailing newline).
  check2=false
  if [ -f version ]; then
    lines="$(wc -l < version | xargs)"
    if [ "$lines" -eq 0 ] && grep -Pq "^\d{1,2}\.\d{1,2}\.\d{1,2}$" version; then
      check2=true
    fi
  fi

  # check3: the version file is one of the changed files.
  if git diff --name-only origin/main | grep -q version; then check3=true; else check3=false; fi

  log "  checks: no-net-words=$check1 (added=$gitp removed=$gitm) version-structure=$check2 version-changed=$check3"

  if $check1 && $check2 && $check3; then
    log "  all checks pass -> merging PR #$PR_ID into main"
    code="$(curl -s -m 20 -o /tmp/merge.out -w '%{http_code}' -u "$CREDS" \
            -X POST -H 'Content-Type: application/json' \
            -d '{"Do":"merge"}' "$API/pulls/$PR_ID/merge" 2>/dev/null || echo 000)"
    case "$code" in
      2*) log "  merged PR #$PR_ID ($code)" ;;
      *)  log "  merge of PR #$PR_ID returned $code -> $(tr -d '\n' < /tmp/merge.out | cut -c1-200)" ;;
    esac
  else
    log "  PR #$PR_ID does not look like a tidy version bump; skipping"
  fi

  cd /; rm -rf "$WORK"
done

exit 0
