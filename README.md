# Mock Turtle: insufficient flow control (auto-merge bot bypass) (CyberCTF lab)

A bespoke, self-contained reproduction of the **Mock Turtle** challenge from
[CI/CD Goat](https://github.com/cider-security-research/cicd-goat) — OWASP **CICD-SEC-1,
Insufficient Flow Control Mechanisms**. Wonderland merges code with a bot: a **Jenkins** controller
watches the `Wonderland/mock-turtle` repository (hosted on a **Gitea** server) and **auto-merges** a
pull request into the protected `main` branch when the change looks like a harmless version bump.
The bot checks only three weak conditions — the pull request adds **no net words**, the `version`
file keeps its dotted structure, and the `version` file is one of the changed files. An attacker
with write access appends a flag-exfiltration step to the `Jenkinsfile` and deletes an equal number
of words from the `README.md` (so the net word count stays zero), bumps the version, and opens a
pull request. The bot merges it to `main`; the `main` pipeline then runs the poisoned `Jenkinsfile`
and Wonderland's release token — a **Global-scope** Jenkins credential, `flag10` — lands in the
build console. This is an **auto-merge bypass via insufficient flow control**.

**Private lab content — do not copy into any public repository.**

## Infrastructure

Two machines, the minimum a live auto-merge attack needs:

| Machine | What |
|---|---|
| `jenkins` | Jenkins controller, configured by Configuration-as-Code. A Job DSL seed creates two git-polling pipelines: **`mock-turtle-automerge`** (the auto-merge bot — runs every minute, evaluates each open pull request against the three checks and merges a passing one into `main` over the Gitea API) and **`mock-turtle`** (builds the `main` branch's own `Jenkinsfile`; pull-request branches are never built here). `flag10` is a **Global-scope** credential the poisoned `main` pipeline binds; builds run on the controller's own executor. `git` + `curl` + `jq` are present for the bot and the in-machine solver. |
| `gitea` | Gitea git host. The setup job provisions the `Wonderland` org, the private `mock-turtle` repo, the attacker `alice` (write), the bot `mock-turtle-ci` (write) and the poller `jenkins` (read), pushes the sample project, then **protects `main`** so push and merge are restricted to the bot — `alice` can open pull requests but can neither push to `main` nor merge them, so the bot is the only path onto `main`. |

No GitLab, CTFd, prod box or SSH agents — only what this one vulnerability needs. The web ports
listen on container `8080` (Jenkins) and `3000` (Gitea); the host ports are assigned dynamically by
the runner (see below). Jenkins is slow to boot — allow a few minutes.

## Objective

One per-player objective (`.ctf/objectives.json`), graded by CyberBackend:

| Key | Evidence | What the player recovers |
|---|---|---|
| `mock-turtle` | `SECRET` (`%s`) | Wonderland's `flag10` release token, exfiltrated from the Jenkins credential store by the `main` pipeline once the crafted pull request auto-merges |

Intended path: clone `Wonderland/mock-turtle` with write creds → append a
`withCredentials([usernamePassword(credentialsId: 'flag10', ...)]) { sh 'echo $TOKEN | rev | base64' }`
stage to the `Jenkinsfile` → bump the `version` (keep `x.y.z`) → delete the same number of words from
the `README.md` so the pull request adds **no net words** → open a pull request → the bot merges it
to `main` → the `main` pipeline runs the poisoned `Jenkinsfile` and prints the exfiltrated blob →
`base64 -d | rev` to recover the token. The recovered token is the flag. (Modern Jenkins masks the
raw value *and* its plain base64; reversing first evades the masker — see UPSTREAM.md.)

## Per-player flag

The flag is issued per player by CyberCTF and handed to the lab by the launcher as a **file**
(`isoloom.yml` `inputs: [CTF_FLAG_MOCK_TURTLE]`, delivered via
`files: [{ path: /run/lab/secrets/flag10, input: CTF_FLAG_MOCK_TURTLE }]` on the Jenkins machine),
never an environment variable, so it never appears in `docker inspect`, an image layer or a
generated file. The Jenkins entrypoint stages the file into the directory JCasC reads file secrets
from, so `flag10` (`password: "${flag10}"`) resolves at boot **into the credential store only** — a
pipeline must bind the credential to read it, exactly as in the challenge.

An **offline start** (local, CI) leaves the input empty, and the lab stages its development
placeholder (`.ctf/objectives.json` `dev`) instead, so it still comes up and is solvable without a
launcher.

## Dynamic ports

Both web services declare `ports: { web: { port: <n>, protocol: http, publish: true } }`.
`publish: true` asks the runner for a **free host port it picks at `up` time** — there is no fixed
host port anywhere in the spec, message, configs or checks (the only literals are in-container
loopback and the lab network CIDR, `10.44.0.0/24`). The `message` reads the real URLs back through
`{{ machines.jenkins.ports.web.url }}` and `{{ machines.gitea.ports.web.url }}`.

## Run it

Described once in [`isoloom.yml`](isoloom.yml) ([Isoloom](https://www.isoloom.com)); run on Docker
through the [Isothrum](https://www.isothrum.com) runner:

```bash
isoloom validate .
isoloom generate . --target docker
isothrum up . --target docker          # add --secret-from-env CTF_FLAG_MOCK_TURTLE for a real value
isothrum check . --target docker       # Jenkins is slow; the solver waits for the merge + build
isothrum down . --target docker
```

Solve it the way the check does:

```bash
git clone http://alice:alice@<gitea-url>/Wonderland/mock-turtle.git
cd mock-turtle && git checkout -b bump
# edit Jenkinsfile: add a stage with withCredentials([usernamePassword(credentialsId:'flag10',...)]){ sh 'echo $TOKEN | rev | base64' }
# bump version (keep x.y.z); delete the same number of words from README.md so the net is 0
git commit -am "Bump version" && git push origin bump
# open a PR in Gitea; the bot auto-merges it to main; read the main build console in Jenkins:
# `base64 -d <blob> | rev` is the flag
```

## Layout

- `build/jenkins/Dockerfile` — Jenkins LTS + plugins + git/curl/jq, runs as root to read the mounted secret
- `build/jenkins/casc/jenkins.yaml` — Configuration-as-Code: the Global-scope `flag10` credential, the bot/poller creds, security, the Job DSL seed
- `build/jenkins/casc/jobdsl/mock-turtle.groovy` — the two pipelines: the auto-merge bot (1-minute cron) and the `main` build (git poll, pipeline from SCM)
- `build/jenkins/entrypoint.sh` — stages the per-player flag into the JCasC file-secret directory
- `build/jenkins/automerge.sh` — the auto-merge bot (`/usr/local/bin/mock-turtle-automerge`): the exact three checks + the Gitea merge call
- `build/jenkins/solve.sh` — the solver / self-check (`/usr/local/bin/mock-turtle-solve`): performs the auto-merge bypass end to end and proves the flag was exfiltrated, never printing it
- `build/gitea/Dockerfile`, `app.ini`, `entrypoint.sh` — the installed Gitea host
- `build/gitea/seed.sh` — the `setup` step: provisions the org/users/repo, pushes the sample project, protects `main`
- `build/gitea/repo-src/` — the original `mockturtle` package, its `version` file and `Jenkinsfile`
- `.ctf/` — `metadata.json` and `objectives.json` (the catalogue registration)
- `UPSTREAM.md` — attribution, and the faithful deviations (the auto-merge implementation, the trigger, the masking transform)
- `.isoloom/` — generated by `isoloom generate` (git-ignored; don't edit)
