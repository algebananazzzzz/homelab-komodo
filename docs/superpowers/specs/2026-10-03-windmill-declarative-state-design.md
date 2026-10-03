# Windmill declarative state

## Goal

If the `windmill` database is lost, Windmill can be rebuilt to a working state from git and Komodo variables alone, plus a short manual runbook. Changes flow both ways: a push to `homelab-windmill` deploys to Windmill, and a change made in Windmill (UI, MCP agent, API) lands on `homelab-windmill` main without being flagged or overwritten.

Out of scope: job history, run logs and the audit log. A future dump routine will cover those. Its output holds the secrets and the workspace key that decrypts them, so its destination must be treated as secret storage.

## Current state

- `homelab-komodo` deploys the Windmill containers (`stacks/apps/windmill/compose.yml`, `komodo/apps.toml`).
- Instance configuration was set by hand through the API: Authelia OAuth, `disable_password_login`, `require_preexisting_user_for_oauth`, the superadmin user `daniel.zhouqx@gmail.com`, and the `homelab` workspace. None of it is declared.
- `homelab-windmill` holds the `homelab` workspace content under `f/**`. CI runs `wmill sync push` on every push to main. A nightly drift job fails when Windmill differs from main, after which the next deploy overwrites the UI change.
- Secret variables (`skipSecrets: true`) exist only in Windmill's database.

## Layers and ownership

| Layer | Source of truth | Applied by |
|---|---|---|
| Instance: global settings, users, instance groups, worker configs | `homelab-komodo` `stacks/apps/windmill/config/` | `bootstrap` service on every Komodo deploy |
| Workspace existence and the git sync token | `homelab-komodo` bootstrap and Komodo variables | `bootstrap` service |
| Workspace content, git sync settings, git sync resource | `homelab-windmill` main | `bootstrap` seeds a newly created workspace; after that, CI for pushes to the repo and Windmill git sync for changes made in Windmill |
| Workspace secret values | Not stored | Re-entered by hand, listed by the `$var:` check |
| API tokens (GitHub CI, MCP clients) | Not stored | Re-issued by hand after a rebuild |

Workspace secrets are not mirrored anywhere. Most are keys issued by other homelab apps whose state lives in the same Postgres cluster, so the outages that lose Windmill's database usually invalidate them anyway. External keys are few and cheap to re-enter.

## New Komodo variables

- `WINDMILL_SUPERADMIN_SECRET`: 64 random hex characters, passed to Windmill's `SUPERADMIN_SECRET` env var (present in v1.820.0). It acts as a superadmin bearer token that lives outside the database, so the bootstrap can authenticate against an empty database. It goes to the `server` and `bootstrap` containers only, never to `worker`, so scripts cannot read it.
- `WINDMILL_GIT_SYNC_TOKEN`: a fine-grained GitHub PAT with contents read and write on `algebananazzzzz/homelab-windmill` only, no expiry.

`WINDMILL_OIDC_CLIENT_SECRET` already exists and is reused.

## homelab-komodo changes

### `stacks/apps/windmill/config/`

The instance files in the format `wmill instance pull` writes: `instance_settings.yaml`, `instance_users.yaml`, `instance_groups.yaml`, `instance_configs.yaml`. They are captured once from the live instance, then secrets are replaced with environment placeholders (`${WINDMILL_OIDC_CLIENT_SECRET}`). Volatile or instance-generated values (license keys, generated IDs, timestamps) are removed if the CLI tolerates their absence.

### `bootstrap` service

A one-shot service in `compose.yml`, built the same way as `register`:

- Image `node:22-alpine` with `windmill-cli` pinned to the server image version.
- `depends_on: server: condition: service_healthy`. The `server` service gains a healthcheck against `/api/version`.
- Environment: `WM_URL=http://server:8000`, `WM_TOKEN` from `WINDMILL_SUPERADMIN_SECRET`, `WINDMILL_OIDC_CLIENT_SECRET`, `WINDMILL_GIT_SYNC_TOKEN`.
- Mounts `bootstrap.sh` and `config/` read-only.
- Listed in `ignore_services` in `komodo/apps.toml`, like `register`, so a completed one-shot does not show the stack as unhealthy.

`bootstrap.sh` runs on every deploy, each step idempotent, and exits non-zero on any failure:

1. Render `config/` into a temp directory with the secrets substituted, then run `wmill instance push --yes` from it.
2. Create the `homelab` workspace if it does not exist, and remember whether it did.
3. Create or update the secret variable that the git sync resource references (path decided during implementation, for example `f/git_sync/token`) from `WINDMILL_GIT_SYNC_TOKEN`.
4. Only if step 2 created the workspace: clone `homelab-windmill` main (public, no credential needed), `npm ci` in it so the repo's own pinned CLI is used, then run `wmill sync push --yes` and `wmill gitsync-settings push --yes` against the new workspace. On an existing workspace CI owns content, so this step is skipped.

The image therefore needs `git` alongside Node.

### Komodo stack config

- `environment` adds `WINDMILL_SUPERADMIN_SECRET='[[WINDMILL_SUPERADMIN_SECRET]]'`, `WINDMILL_OIDC_CLIENT_SECRET='[[WINDMILL_OIDC_CLIENT_SECRET]]'` and `WINDMILL_GIT_SYNC_TOKEN='[[WINDMILL_GIT_SYNC_TOKEN]]'`, single-quoted as the other stacks are.
- `config_files` adds `bootstrap.sh` and every file in `config/`, so a change to them redeploys the stack.

### Renovate

A package rule groups the Windmill server image and the bootstrap's `windmill-cli` version so they move in one PR. `homelab-windmill`'s `package.json` CLI version is still bumped by hand, and its existing CI check fails if it skews from the server.

## homelab-windmill changes

### Git sync

- `wmill.yaml` gains git sync settings: sync mode, repository `homelab-windmill`, branch `main`, and the same object types the repo already syncs (scripts, flows, apps, folders, resources, non-secret variables, schedules, triggers). Secrets are excluded.
- A `git_repository` resource under `f/` whose token is a `$var:` reference to the variable the bootstrap writes. It passes the existing plain-text credential check.
- Windmill commits each deploy made in Windmill to main with a `[WM]` prefix. Git sync is available on Community Edition for workspaces with up to 2 users; `homelab` has one.

### `sync.yml`

- The `deploy` job is skipped when the head commit message starts with `[WM]`, because that content is already live.
- After `wmill sync push`, the job runs `wmill gitsync-settings push --yes`.

### `drift.yml`

- Keeps the `wmill sync pull --dry-run` comparison. A difference now means git sync failed, and the error message says so.
- Adds a `$var:` check: every `$var:<path>` reference in the repo must exist as a variable in the workspace. Missing ones are listed and fail the job. After a rebuild, this list is the set of secrets to re-enter.

## Recovery runbook (empty `windmill` database)

1. Deploy the Windmill stack in Komodo, or run the `cold-start` procedure. The bootstrap restores instance settings, users and login, creates the `homelab` workspace, writes the git sync token, and seeds the workspace content and git sync settings from `homelab-windmill` main.
2. Sign in through Authelia, mint an API token and update `WMILL_TOKEN` in the `homelab-windmill` GitHub secrets.
3. Run the `drift` workflow. Re-enter each secret it lists in the Windmill UI, then run it again until it passes.
4. Mint new tokens for any MCP client that talks to Windmill.

## Security notes

- Komodo already holds `POSTGRES_PASSWORD`, a superuser on the shared cluster, so the new variables do not add a party who can read Windmill's secrets.
- `SUPERADMIN_SECRET` is a static, non-expiring superadmin token on a public instance. It is long and random, never reaches the worker, and is rotated by changing the Komodo variable and redeploying.
- The existing weakness remains and is worse: any script can read the worker's `DATABASE_URL`, which is the Postgres superuser.

## Risks verified during implementation

- **Echo commits.** A CI deploy may trigger git sync to commit the same content back. If Windmill re-serializes files so they differ, the result is noise commits. Verify on the test instance; if they occur, decide between excluding CI deploys from git sync and normalizing the repo to Windmill's serialization.
- **What `wmill instance push` deletes.** It overwrites the remote. Confirm on the test instance whether it removes users, groups or settings absent from `config/` (for example `admin@windmill.dev`) before it runs against the live instance.
- **Silent git sync failure.** If a git sync commit fails, the next CI push deletes the unsynced item. Deleted items stay recoverable with `wmill trash` for three days, and the nightly drift job reports the gap.
- **Push races.** A `[WM]` commit landing while a PR is open is an ordinary concurrent change on main. A direct push to main that is behind is rejected by GitHub as non-fast-forward.

## Testing

1. A throwaway local stack: its own empty Postgres container, the pinned Windmill image, and the real `bootstrap` service and `config/`, with a test OIDC secret and a scratch git sync token. Check that password login is disabled, the OAuth provider is configured, the superadmin user exists, the `homelab` workspace exists, the git sync variable is set, `f/kaneo` and its schedule were seeded, and the git sync settings match `wmill.yaml`.
2. Run the bootstrap a second time and confirm it changes nothing and does not re-seed. Run the `$var:` check against the local instance and confirm it reports `f/kaneo/api_key` as missing.
3. Only after both pass, deploy to the live instance, enable git sync, and make a UI edit to confirm a `[WM]` commit reaches main and CI skips it.
