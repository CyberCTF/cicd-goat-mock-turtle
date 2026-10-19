# Upstream

This lab reproduces one challenge — **Mock Turtle** — from CI/CD Goat.

| What | Source | Licence |
| --- | --- | --- |
| The "Mock Turtle" challenge (auto-merge bot bypass via a naive word-count rule) | [CI/CD Goat](https://github.com/cider-security-research/cicd-goat) by Cider Security (now Palo Alto Networks), v1.2.7 | Apache-2.0 |
| Security class | [OWASP CICD-SEC-1: Insufficient Flow Control Mechanisms](https://owasp.org/www-project-top-10-ci-cd-security-risks/CICD-SEC-01-Insufficient-Flow-Control-Mechanisms) | — |
| The word-count idea | Ryotak, [Homebrew security incident](https://blog.ryotak.me/post/homebrew-security-incident-en/); and [this Stack Overflow answer](https://stackoverflow.com/a/31823590/6691195) on counting a word diff | — |

Only the *vulnerability* is reproduced, not upstream's eight-machine CI/CD stack. The lab is two
machines — a Jenkins controller and a Gitea git host — which is the minimum this attack needs: a
repository, an auto-merge mechanism whose criteria are too weak, and a credential a merged pipeline
can read.

Nothing is vendored from upstream. Upstream serves a copy of a third-party project as the
`mock-turtle` repository and bakes one fixed UUID flag into Jenkins. This lab instead ships an
**original** minimal sample package (`build/gitea/repo-src/`, authored here, no third-party code: a
"timetable" package themed on the Mock Turtle's seaside school) with an original `Jenkinsfile`,
`version` file and `README.md`, and injects a **per-player** flag into the Jenkins credential store
at run time, so each player exfiltrates their own flag and nothing but the challenge idea comes from
upstream.

## The auto-merge rule is reproduced exactly

The crux of the challenge is the auto-merge bot's three naive checks. They are reproduced verbatim
(`build/jenkins/automerge.sh`), matching upstream's Jenkinsfile logic:

1. **No net words added.** `git diff --word-diff=porcelain origin/main`, counting added-word lines
   (`^+[^+]`) and removed-word lines (`^-[^-]`) with `wc -w`; the check is `added - removed == 0`.
   A pure version bump removes one word (the old version) and adds one (the new version), so it is
   net zero — the intended, "safe" change. The attacker appends a payload to the `Jenkinsfile` and
   deletes an equal number of words from the `README.md`, so the net is still zero.
2. **Version structure unchanged.** The `version` file is a single line (no trailing newline, so
   `wc -l` is `0`) and matches `^\d{1,2}\.\d{1,2}\.\d{1,2}$`.
3. **Version file changed.** `version` appears in `git diff --name-only origin/main`.

The second and third checks never verify *which other* files changed or *what* was added, so the
payload rides along in the `Jenkinsfile` while the three checks all pass.

## Faithful deviations (and why)

Upstream wires Mock Turtle as a **single Jenkins multibranch pipeline** whose `Jenkinsfile` (pinned
to `main` via the *remote-file* provider plugin, with pull-request discovery via the *Gitea*
plugin) does double duty: on a pull-request build it runs the auto-merge checks and merges; after
the merge, the same file — now carrying the attacker's prepended `withCredentials` block — runs on
`main` and exfiltrates the flag. That wiring depends on two version-fragile plugins (the Gitea
plugin for pull-request discovery and the remote-file provider for the pinned `Jenkinsfile`), which
is exactly the kind of Jenkins↔plugin coupling that makes a lab family brittle to run unattended.

This lab keeps the **vulnerability and the attacker's steps identical** but makes the plumbing
robust and deterministic, with two decoupled, plugin-light pieces (the challenge explicitly allows
implementing the auto-merge "as a small service or a Jenkins job"):

- **The auto-merge bot is its own Jenkins job** (`mock-turtle-automerge`), a plain scripted step on
  a 1-minute cron that lists open pull requests over the Gitea API, runs the *exact* three checks
  above on each, and merges a passing one over the Gitea API with the bot's write credential. No
  Gitea plugin, no pull-request SCM discovery.
- **The `main` build is a separate "pipeline script from SCM" job** (`mock-turtle`) pinned to the
  `main` branch and polled over git — the robust pattern proven by the White Rabbit lab. It builds
  only `main`, so an attacker's pull-request branch is never built directly (that would be poisoned
  pipeline execution, a different class); the attacker's change runs only *after* the bot merges it
  onto `main`, which is the whole point of the flow-control lesson.
- **`main` is a protected branch** (push and merge restricted to the bot user). Upstream relies on
  the workflow convention that changes reach `main` through the bot; this lab enforces it, so the
  auto-merge bypass is genuinely the only path onto `main` (the attacker, `alice`, cannot push to
  `main` or merge her own pull request). The player-facing flow is unchanged: clone, craft a
  bypassing pull request, open it, let the bot merge it, read the `main` build console.

The attack is the same end to end: craft a pull request that adds no net words yet still poisons the
`Jenkinsfile`, bump the version, open the pull request, let the bot auto-merge it, and read the flag
from the `main` build's console.

## A note on masking (the exfiltration encoding)

Upstream's solution prints `echo $TOKEN | base64`, relying on base64 slipping past credential
masking. On the modern Jenkins this lab ships, the `credentials-binding` plugin masks a bound
secret's raw value **and its plain base64**, so that exact trick no longer works. The lab keeps the
vulnerability identical and only updates the encoding the attacker uses to one the masker does not
precompute — reversing before base64 (`echo $TOKEN | rev | base64`, recovered with
`base64 -d | rev`). This is arguably a truer lesson for current CI: masking is a best-effort
guardrail, not a control, and a chosen transform defeats it.
