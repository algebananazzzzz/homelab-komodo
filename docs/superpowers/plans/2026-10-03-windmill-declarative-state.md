# Windmill declarative state Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Windmill from git plus Komodo variables after a database loss, and sync workspace changes both ways between Windmill and `homelab-windmill`.

**Architecture:** A one-shot `bootstrap` service in the Komodo Windmill stack applies declared instance settings, users, workspace and git sync config through the REST API, authenticating with `SUPERADMIN_SECRET`, and seeds content into a newly created workspace. Windmill's native git sync commits Windmill-side changes to `homelab-windmill` main as `[WM]` commits, and the existing CI keeps deploying human pushes.

**Tech Stack:** Docker Compose, Komodo resource sync, POSIX sh with curl and jq, Windmill 1.820.0 REST API, windmill-cli 1.820.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-03-windmill-declarative-state-design.md`

## Global Constraints

- Windmill server image `ghcr.io/windmill-labs/windmill:1.820.0`; `homelab-windmill` CLI `windmill-cli` 1.820.0.
- Bootstrap image `node:22.23.3-alpine`.
- Komodo env values are single-quoted: `KEY='[[VAR]]'`.
- `SUPERADMIN_SECRET` reaches `server` and `bootstrap` only, never `worker`.
- No secret value is ever printed: not in script output, not in tool output, not in commits.
- Workspace id `homelab`, owner `daniel.zhouqx@gmail.com`, owner username `danielzhouqx`.
- Git sync variable path `f/git_sync/repo_url`, resource path `f/git_sync/homelab_windmill`.
- Never print merged Ansible inventory vars.
- User conventions: no em dashes, imperative commit subjects, comments explain why only.

## Review Focus

- Bootstrap run against the live instance, where everything already exists: it must change nothing except writing the git sync variable and config the first time.
- A Windmill API call failing midway (wrong body, 4xx): the bootstrap must exit non-zero so Komodo shows the deploy failed, instead of reporting success.
- `env:NAME` placeholder whose variable is unset: must fail, never write an empty secret.
- A `[WM]` commit landing on main: CI must skip the deploy, and a normal merge must still deploy.
- `check-vars.sh` against a workspace missing a referenced variable: must list it and exit non-zero; with all present it must exit zero.

---

### Task 1: homelab-windmill git sync content and CI

**Files (in `/home/daniel/github.com/algebananazzzzz/homelab-windmill`):**
- Create: `f/git_sync/folder.meta.yaml`
- Create: `f/git_sync/homelab_windmill.resource.yaml`
- Create: `scripts/check-vars.sh`
- Modify: `.github/workflows/sync.yml` (deploy job `if:`)
- Modify: `.github/workflows/drift.yml` (message, new step)

**Interfaces:**
- Produces: folder `f/git_sync` and resource `f/git_sync/homelab_windmill` with `url: $var:f/git_sync/repo_url`, which Task 2's bootstrap fills and references.
- Produces: `scripts/check-vars.sh <base-url> <workspace> <token>`, exit 1 and lists missing paths.

- [ ] **Step 1: Branch**

```bash
cd /home/daniel/github.com/algebananazzzzz/homelab-windmill && git switch main && git pull --ff-only && git switch -c git-sync
```

- [ ] **Step 2: Add the folder and resource**

`f/git_sync/folder.meta.yaml`:

```yaml
summary: null
display_name: git_sync
owners:
  - u/danielzhouqx
extra_perms:
  u/danielzhouqx: true
```

`f/git_sync/homelab_windmill.resource.yaml`:

```yaml
description: This repository; Windmill git sync commits workspace changes to it.
resource_type: git_repository
# The variable holds the whole authenticated URL and is written by the homelab-komodo bootstrap.
value:
  url: $var:f/git_sync/repo_url
  branch: main
```

- [ ] **Step 3: Write `scripts/check-vars.sh`**

```sh
#!/bin/sh
# Lists every $var: reference under f/ that has no variable in the workspace. After a rebuild these are the secrets to re-enter.
set -eu
base_url=$1 workspace=$2 token=$3

missing=0
for path in $(grep -rhoE '\$var:[A-Za-z0-9_/.-]+' f | sed 's/^\$var://' | sort -u); do
  exists=$(curl -sS --fail-with-body -H "Authorization: Bearer $token" "$base_url/api/w/$workspace/variables/exists/$path")
  if [ "$exists" != true ]; then
    echo "missing variable: $path"
    missing=1
  fi
done
exit $missing
```

`chmod +x scripts/check-vars.sh`.

- [ ] **Step 4: Check the script parses and finds the references**

No Windmill token is available locally, so the behavior test runs against the throwaway instance in Task 4, Step 6.

Run: `sh -n scripts/check-vars.sh && grep -rhoE '\$var:[A-Za-z0-9_/.-]+' f | sort -u`
Expected: no syntax error; prints `$var:f/git_sync/repo_url` and `$var:f/kaneo/api_key`.

- [ ] **Step 5: Skip `[WM]` deploys in `sync.yml`**

Replace the deploy job's `if: github.event_name == 'push'` with:

```yaml
    # Windmill git sync commits with a [WM] prefix after the change is already live.
    if: github.event_name == 'push' && !startsWith(github.event.head_commit.message, '[WM]')
```

- [ ] **Step 6: Update `drift.yml`**

Replace the header comment and error text, and add the variable check:

```yaml
name: drift

# Git sync commits every Windmill-side change to main, so a difference here means git sync failed.
```

In the `Windmill matches main` step, change the error line to:

```sh
            echo "::error::Windmill differs from main, so git sync has failed. Check the git sync job in Windmill before the next deploy deletes the unsynced change."
```

Append a step:

```yaml
      - name: Every $var reference has a variable
        env:
          WMILL_TOKEN: ${{ secrets.WMILL_TOKEN }}
        run: scripts/check-vars.sh https://windmill.algebananazzzzz.com homelab "$WMILL_TOKEN"
```

- [ ] **Step 7: Lint and test**

Run: `npm test && npx wmill lint`
Expected: both pass.

- [ ] **Step 8: Commit, push, open PR**

```bash
git add f/git_sync scripts/check-vars.sh .github/workflows/sync.yml .github/workflows/drift.yml
git commit -m "Add the git sync resource and skip deploying Windmill's own commits"
git push -u origin git-sync
gh pr create --fill
```

Expected: the `check` and `plan` jobs pass; `plan` shows the folder and resource being added.

- [ ] **Step 9: Merge**

`gh pr merge --merge --delete-branch`, then watch the deploy run succeed: `gh run watch`.

### Task 2: bootstrap config and script

**Files (in `homelab-komodo`):**
- Create: `stacks/apps/windmill/config/settings.json`
- Create: `stacks/apps/windmill/config/users.json`
- Create: `stacks/apps/windmill/config/workspace.json`
- Create: `stacks/apps/windmill/config/git_sync.json`
- Create: `stacks/apps/windmill/bootstrap.sh`

**Interfaces:**
- Consumes: Task 1's `f/git_sync` folder and resource on `homelab-windmill` main.
- Produces: `bootstrap.sh` reading env `WM_URL`, `SUPERADMIN_SECRET`, `WINDMILL_OIDC_CLIENT_SECRET`, `WINDMILL_ADMIN_PASSWORD`, `WINDMILL_GIT_SYNC_TOKEN` and `/config/*.json`.

- [ ] **Step 1: Write `config/settings.json`** (values from the live `global_settings` table)

```json
{
  "base_url": "https://windmill.algebananazzzzz.com",
  "disable_password_login": true,
  "require_preexisting_user_for_oauth": true,
  "oauths": {
    "authelia": {
      "id": "windmill",
      "secret": "env:WINDMILL_OIDC_CLIENT_SECRET",
      "display_name": "Authelia",
      "login_config": {
        "scopes": ["openid", "profile", "email", "groups"],
        "auth_url": "https://auth.algebananazzzzz.com/api/oidc/authorization",
        "token_url": "https://auth.algebananazzzzz.com/api/oidc/token",
        "userinfo_url": "https://auth.algebananazzzzz.com/api/oidc/userinfo"
      },
      "connect_config": {
        "scopes": ["openid", "profile", "email", "groups"],
        "auth_url": "https://auth.algebananazzzzz.com/api/oidc/authorization",
        "token_url": "https://auth.algebananazzzzz.com/api/oidc/token"
      }
    }
  }
}
```

- [ ] **Step 2: Write `config/users.json`, `config/workspace.json`, `config/git_sync.json`**

```json
[
  {
    "email": "daniel.zhouqx@gmail.com",
    "name": "danielz",
    "super_admin": true,
    "login_type": "authelia"
  }
]
```

```json
{
  "id": "homelab",
  "name": "Homelab",
  "owner_email": "daniel.zhouqx@gmail.com",
  "owner_username": "danielzhouqx"
}
```

```json
{
  "repositories": [
    {
      "git_repo_resource_path": "$res:f/git_sync/homelab_windmill",
      "use_individual_branch": false,
      "group_by_folder": false,
      "settings": {
        "include_path": ["f/**"],
        "include_type": ["script", "flow", "app", "folder", "resource", "variable", "schedule", "trigger"],
        "exclude_path": [],
        "extra_include_path": []
      }
    }
  ]
}
```

- [ ] **Step 3: Write `bootstrap.sh`**

```sh
#!/bin/sh
# Brings a Windmill instance, empty or not, to the state declared in /config. Runs on every deploy of the stack.
set -euo pipefail

CONTENT_REPO=algebananazzzzz/homelab-windmill
URL_VARIABLE=f/git_sync/repo_url

api() {
  token=$1 method=$2 path=$3
  shift 3
  curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' "$@" "$WM_URL/api$path"
}
as_superadmin() { api "$SUPERADMIN_SECRET" "$@"; }

# Only the declared keys are managed: jwt_secret, uid and the other generated settings stay Windmill's.
jq -c 'walk(if type == "string" and startswith("env:") then ($ENV[.[4:]] // error("\(.[4:]) is not set")) else . end) | to_entries[]' /config/settings.json >/tmp/settings
while read -r entry; do
  key=$(printf '%s' "$entry" | jq -r .key)
  want=$(printf '%s' "$entry" | jq -cS .value)
  have=$(as_superadmin GET "/settings/global/$key" | jq -cS .)
  if [ "$have" != "$want" ]; then
    printf '%s' "$entry" | jq -c '{value}' | as_superadmin POST "/settings/global/$key" --data-binary @- >/dev/null
    echo "set $key"
  fi
done </tmp/settings
rm /tmp/settings

jq -c '.[]' /config/users.json >/tmp/users
while read -r user; do
  email=$(printf '%s' "$user" | jq -r .email)
  if [ "$(as_superadmin GET "/users/exists/$email")" != true ]; then
    printf '%s' "$user" | as_superadmin POST /users/create --data-binary @- >/dev/null
    echo "created user $email"
  fi
done </tmp/users
rm /tmp/users

# A fresh database creates this account with the password "changeme". Password login is disabled, but break-glass re-enables it.
jq -n '{password: $ENV.WINDMILL_ADMIN_PASSWORD}' | as_superadmin POST /users/set_password_of/admin@windmill.dev --data-binary @- >/dev/null

workspace=$(jq -r .id /config/workspace.json)
owner=$(jq -r .owner_email /config/workspace.json)

# Windmill refuses the superadmin-secret identity as a schedule's on_behalf_of, so content is written as the owner.
expiration=$(date -u -d "@$(($(date +%s) + 900))" +%Y-%m-%dT%H:%M:%SZ)
owner_token=$(jq -n --arg email "$owner" --arg expiration "$expiration" '{impersonate_email: $email, label: "bootstrap", expiration: $expiration}' |
  as_superadmin POST /users/tokens/impersonate --data-binary @-)
as_owner() { api "$owner_token" "$@"; }

created=false
if [ "$(jq -n --arg id "$workspace" '{id: $id}' | as_superadmin POST /workspaces/exists --data-binary @-)" != true ]; then
  jq '{id, name, username: .owner_username}' /config/workspace.json | as_owner POST /workspaces/create --data-binary @- >/dev/null
  created=true
  echo "created workspace $workspace"
fi

# Seeding runs before git sync is configured, so it does not commit the seeded content back.
if [ "$created" = true ]; then
  git clone --quiet --depth 1 "https://github.com/$CONTENT_REPO" /tmp/content
  cd /tmp/content
  npm ci --no-audit --no-fund --loglevel=error
  npx wmill sync push --yes --locks-required --skip-branch-validation --message bootstrap --workspace "$workspace" --base-url "$WM_URL" --token "$owner_token"
  cd /
  echo "seeded $workspace from $CONTENT_REPO"
fi

# A $var: reference must be a whole field value, so the variable holds the full authenticated URL.
export GIT_SYNC_URL="https://x-access-token:$WINDMILL_GIT_SYNC_TOKEN@github.com/$CONTENT_REPO.git"
body=$(jq -n --arg path "$URL_VARIABLE" '{path: $path, value: $ENV.GIT_SYNC_URL, is_secret: true, description: "Authenticated URL git sync pushes to, written by the homelab-komodo bootstrap."}')
if [ "$(as_owner GET "/w/$workspace/variables/exists/$URL_VARIABLE")" != true ]; then
  printf '%s' "$body" | as_owner POST "/w/$workspace/variables/create" --data-binary @- >/dev/null
  echo "created $URL_VARIABLE"
elif [ "$(as_owner GET "/w/$workspace/variables/get_value/$URL_VARIABLE" | jq -r .)" != "$GIT_SYNC_URL" ]; then
  printf '%s' "$body" | as_owner POST "/w/$workspace/variables/update/$URL_VARIABLE" --data-binary @- >/dev/null
  echo "updated $URL_VARIABLE"
fi

jq '{git_sync_settings: .}' /config/git_sync.json | as_owner POST "/w/$workspace/workspaces/edit_git_sync_config" --data-binary @- >/dev/null
echo "bootstrap done"
```

`chmod +x stacks/apps/windmill/bootstrap.sh`

- [ ] **Step 4: Syntax and placeholder check**

Run:

```bash
cd /home/daniel/github.com/algebananazzzzz/homelab-komodo/stacks/apps/windmill
sh -n bootstrap.sh && for f in config/*.json; do jq empty "$f"; done
env -u WINDMILL_OIDC_CLIENT_SECRET jq -c 'walk(if type == "string" and startswith("env:") then ($ENV[.[4:]] // error("\(.[4:]) is not set")) else . end)' config/settings.json; echo "exit $?"
```

Expected: no output from the syntax checks, then `jq: error ... WINDMILL_OIDC_CLIENT_SECRET is not set` and `exit 5`.

### Task 3: compose and Komodo wiring

**Files:**
- Modify: `stacks/apps/windmill/compose.yml` (server healthcheck and env, new `bootstrap` service)
- Modify: `komodo/apps.toml` (windmill `ignore_services`, `environment`, `config_files`)

**Interfaces:**
- Consumes: Task 2's `bootstrap.sh` and `config/`.

- [ ] **Step 1: Server healthcheck and secret**

In `server.environment` add `SUPERADMIN_SECRET: ${SUPERADMIN_SECRET:?}`. Add to `server`:

```yaml
    healthcheck:
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8000/api/version"]
      interval: 5s
      timeout: 3s
      retries: 60
```

- [ ] **Step 2: Add the bootstrap service** after `worker`:

```yaml
  bootstrap:
    image: node:22.23.3-alpine
    depends_on:
      server:
        condition: service_healthy
    entrypoint: ["/bin/sh", "-c", "apk add --no-cache --quiet curl jq git && exec /bootstrap.sh"]
    environment:
      WM_URL: http://server:8000
      SUPERADMIN_SECRET: ${SUPERADMIN_SECRET:?}
      WINDMILL_OIDC_CLIENT_SECRET: ${WINDMILL_OIDC_CLIENT_SECRET:?}
      WINDMILL_ADMIN_PASSWORD: ${WINDMILL_ADMIN_PASSWORD:?}
      WINDMILL_GIT_SYNC_TOKEN: ${WINDMILL_GIT_SYNC_TOKEN:?}
    volumes:
      - ./bootstrap.sh:/bootstrap.sh:ro
      - ./config:/config:ro
```

- [ ] **Step 3: Komodo stack config** for `windmill` in `komodo/apps.toml`:

```toml
ignore_services = ["register", "bootstrap"]
# Single quotes keep Compose from expanding a `$` inside a value.
environment = """
POSTGRES_PASSWORD='[[POSTGRES_PASSWORD]]'
SUPERADMIN_SECRET='[[WINDMILL_SUPERADMIN_SECRET]]'
WINDMILL_OIDC_CLIENT_SECRET='[[WINDMILL_OIDC_CLIENT_SECRET]]'
WINDMILL_ADMIN_PASSWORD='[[WINDMILL_ADMIN_PASSWORD]]'
WINDMILL_GIT_SYNC_TOKEN='[[WINDMILL_GIT_SYNC_TOKEN]]'
"""
# A sync redeploys a stack only when a listed file changes, so every file the stack reads is listed.
config_files = ["consul/windmill.json", "bootstrap.sh", "config/settings.json", "config/users.json", "config/workspace.json", "config/git_sync.json"]
```

- [ ] **Step 4: Validate**

Run: `docker compose -f stacks/apps/windmill/compose.yml config --quiet --no-interpolate` (on svc-apps-02 via ssh if docker is not local; it is not, so copy the stack dir there in Task 4 and run it there).

### Task 4: throwaway rebuild test on svc-apps-02

**Files:** none committed. Test files live in `/tmp/wm-test` on svc-apps-02 and the session scratchpad.

- [ ] **Step 1: Copy the stack and write the override**

`compose.test.yml` (scratchpad, copied next to the stack):

```yaml
name: wmtest
services:
  register:
    entrypoint: ["true"]
    command: !reset []
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: test
      POSTGRES_DB: windmill
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "admin"]
      interval: 2s
      retries: 30
  server:
    container_name: wmtest-server
    ports: !reset []
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://admin:test@postgres:5432/windmill?sslmode=disable
  worker:
    container_name: wmtest-worker
    environment:
      DATABASE_URL: postgres://admin:test@postgres:5432/windmill?sslmode=disable
volumes:
  logs:
    name: wmtest-logs
  cache:
    name: wmtest-cache
```

`.env` with dummy values: `POSTGRES_PASSWORD=test`, `SUPERADMIN_SECRET=` random hex, `WINDMILL_OIDC_CLIENT_SECRET=dummy-oidc`, `WINDMILL_ADMIN_PASSWORD=dummy-admin`, `WINDMILL_GIT_SYNC_TOKEN=dummy-pat`.

Run: `rsync -a stacks/apps/windmill/ song@10.10.20.114:/tmp/wm-test/` plus the two scratch files, then on the host `sudo docker compose -f compose.yml -f compose.test.yml config --quiet`.
Expected: exit 0.

- [ ] **Step 2: First bootstrap run on the empty database**

Run: `sudo docker compose -f compose.yml -f compose.test.yml up bootstrap --exit-code-from bootstrap`
Expected: exit 0; output includes `set base_url`, `set oauths`, `set disable_password_login`, `set require_preexisting_user_for_oauth`, `created user daniel.zhouqx@gmail.com`, `created workspace homelab`, `seeded homelab`, `created f/git_sync/repo_url`, `bootstrap done`.

- [ ] **Step 3: Assert the resulting state** with the superadmin secret, from a container on the test network (`curlimages/curl` plus host jq):

- `GET /api/settings/global/disable_password_login` is `true`; `oauths.authelia.secret` equals `dummy-oidc` (compare, do not print).
- `GET /api/users/exists/daniel.zhouqx@gmail.com` is `true`.
- `GET /api/w/homelab/users/list` has `danielzhouqx` with `is_admin: true`.
- `GET /api/w/homelab/scripts/get/p/f/kaneo/daily_automation` returns 200; `GET /api/w/homelab/schedules/get/f/kaneo/daily_automation` returns 200.
- `GET /api/w/homelab/workspaces/get_settings` `.git_sync.repositories[0].git_repo_resource_path` is `$res:f/git_sync/homelab_windmill`.

- [ ] **Step 4: Second run is quiet**

Run: `sudo docker compose -f compose.yml -f compose.test.yml up bootstrap --exit-code-from bootstrap --force-recreate`
Expected: exit 0 and the only line besides apk/compose noise is `bootstrap done`.

- [ ] **Step 5: Failure surfaces**

Run the bootstrap with a wrong token in its env only: `sudo docker compose -f compose.yml -f compose.test.yml run --rm -e SUPERADMIN_SECRET=wrong bootstrap`.
Expected: non-zero exit with a 401 body, no `bootstrap done`.

- [ ] **Step 6: check-vars.sh against the test instance**

Mint a token: `POST /api/users/tokens/impersonate` for the owner. From a `homelab-windmill` checkout on the host, run `scripts/check-vars.sh http://<server-container-ip>:8000 homelab <token>`.
Expected: exit 1, prints `missing variable: f/kaneo/api_key` and not `f/git_sync/repo_url`.

- [ ] **Step 7: Tear down**

`sudo docker compose -f compose.yml -f compose.test.yml down -v` and `rm -rf /tmp/wm-test`. Confirm `sudo docker ps -a --filter name=wmtest` is empty and the live `windmill` container still runs.

- [ ] **Step 8: Commit Tasks 2 and 3**

```bash
git add stacks/apps/windmill komodo/apps.toml docs/superpowers
git commit -m "Restore Windmill's instance config and workspace from a bootstrap service"
```

### Task 5: live rollout

- [ ] **Step 1: User creates Komodo variables** (secret): `WINDMILL_SUPERADMIN_SECRET` (`openssl rand -hex 32`) and `WINDMILL_GIT_SYNC_TOKEN` (fine-grained PAT, `homelab-windmill` only, Contents read and write, no expiry). Confirm with the user before continuing.

- [ ] **Step 2: Merge to main and deploy.** Fast-forward `main` to the branch and push. The `sync` procedure applies within 5 minutes and redeploys the stack because `config_files` changed. Check the stack's deploy log in Komodo for `bootstrap done` and exit 0, and that the only change lines are `created f/git_sync/repo_url` (settings and user already match).

- [ ] **Step 3: Git sync works.** Make a trivial edit in the Windmill UI (the `f/git_sync` folder summary). Expected: a `[WM]` commit on `homelab-windmill` main within a minute, and that push's `sync` run shows `deploy` skipped.

- [ ] **Step 4: No echo from a human push.** Pull that commit locally, revert the summary in the file, push to main. Expected: CI deploys, and no further `[WM]` commit appears within two minutes.

- [ ] **Step 5: Drift workflow passes.** `gh workflow run drift.yml && gh run watch`. Expected: both steps pass.

- [ ] **Step 6: Update memory** `windmill-deployment.md` with the bootstrap, git sync and runbook.
