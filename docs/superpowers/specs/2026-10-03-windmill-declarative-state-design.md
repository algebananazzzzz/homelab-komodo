# Windmill declarative state

## Goal

If the `windmill` database is lost, Windmill can be rebuilt to a working state from git and Komodo variables alone, plus a short manual runbook. Changes flow both ways: a push to `homelab-windmill` deploys to Windmill, and a change made in Windmill (UI, MCP agent, API) lands on `homelab-windmill` main without being flagged or overwritten.

Out of scope: job history, run logs and the audit log. A future dump routine will cover those. Its output holds the secrets and the workspace key that decrypts them, so its destination must be treated as secret storage.

## Current state

- `homelab-komodo` deploys the Windmill containers (`stacks/apps/windmill/compose.yml`, `komodo/apps.toml`).
- Instance configuration was set by hand through the API: Authelia OAuth, `disable_password_login`, `require_preexisting_user_for_oauth`, the superadmin user `daniel.zhouqx@gmail.com` (login type `authelia`), and the `homelab` workspace. None of it is declared.
- `homelab-windmill` holds the `homelab` workspace content under `f/**`. CI runs `wmill sync push` on every push to main. A nightly drift job fails when Windmill differs from main, after which the next deploy overwrites the UI change.
- Secret variables (`skipSecrets: true`) exist only in Windmill's database.

## Layers and ownership

| Layer | Source of truth | Applied by |
|---|---|---|
| Instance: the declared global settings and users | `homelab-komodo` `stacks/apps/windmill/config/` | `bootstrap` service on every Komodo deploy |
| Workspace existence, git sync repository entry, git sync URL variable | `homelab-komodo` `config/` and Komodo variables | `bootstrap` service |
| Workspace content, including the git sync folder and resource | `homelab-windmill` main | `bootstrap` seeds a newly created workspace; after that, CI for pushes to the repo and Windmill git sync for changes made in Windmill |
| Workspace secret values | Not stored | Re-entered by hand, listed by the `$var:` check |
| API tokens (GitHub CI, MCP clients) | Not stored | Re-issued by hand after a rebuild |

Workspace secrets are not mirrored anywhere. Most are keys issued by other homelab apps whose state lives in the same Postgres cluster, so the outages that lose Windmill's database usually invalidate them anyway. External keys are few and cheap to re-enter.

## Why the bootstrap calls the API instead of `wmill instance push`

`wmill instance push` (CLI 1.820.0) treats the local files as the whole instance. It sets every global setting missing from `instance_settings.yaml` to null, which would wipe generated values such as `jwt_secret` and `uid` unless they were committed, and it replaces the full user list. It also logs a failed setting and carries on instead of failing. The bootstrap therefore manages only the keys it declares, through the REST API with `curl` and `jq`, and stops on the first error.

## Komodo variables

New:

- `WINDMILL_SUPERADMIN_SECRET`: 64 random hex characters, passed to Windmill's `SUPERADMIN_SECRET` env var (present in v1.820.0). It acts as a superadmin bearer token that lives outside the database, so the bootstrap can authenticate against an empty database. It goes to the `server` and `bootstrap` containers only, never to `worker`, so scripts cannot read it.
- `WINDMILL_GIT_SYNC_TOKEN`: a fine-grained GitHub PAT with contents read and write on `algebananazzzzz/homelab-windmill` only, no expiry.

Reused: `WINDMILL_OIDC_CLIENT_SECRET` and `WINDMILL_ADMIN_PASSWORD`.

## homelab-komodo changes

### `stacks/apps/windmill/config/`

- `settings.json`: the managed global settings, keyed by name: `base_url`, `oauths`, `disable_password_login`, `require_preexisting_user_for_oauth`, copied from the live instance. A string of the form `env:NAME` is replaced with that environment variable at run time, which is how the OIDC client secret gets in. Every other global setting (`jwt_secret`, `uid`, `custom_tags`, ...) is left to Windmill.
- `users.json`: users to create if missing, in the `POST /api/users/create` body format. Today that is `daniel.zhouqx@gmail.com`, superadmin, login type `pending_oauth`: the first Authelia login adopts the account. Creating it with login type `authelia` fails on a fresh database, because Windmill loads a newly set OAuth client a few seconds later.
- `workspace.json`: the workspace id, display name and owner email. Windmill derives the owner's username (`danielzhouqx`) because `automate_username_creation` is on, and rejects an explicit one.
- `git_sync.json`: the workspace's git sync settings in the `edit_git_sync_config` body format: one repository, resource `f/git_sync/homelab_windmill`, include path `f/**`, and the same object types `homelab-windmill/wmill.yaml` syncs (script, flow, app, folder, resource, variable, schedule, trigger). Secrets are excluded.

### `bootstrap` service and `bootstrap.sh`

A one-shot service in `compose.yml`:

- Image `node:22.23.3-alpine`, installing `curl`, `jq` and `git` at start.
- `depends_on: server: condition: service_healthy`. The `server` service gains a healthcheck against `/api/version`.
- Environment: `WM_URL=http://server:8000`, `SUPERADMIN_SECRET`, `WINDMILL_OIDC_CLIENT_SECRET`, `WINDMILL_ADMIN_PASSWORD`, `WINDMILL_GIT_SYNC_TOKEN`.
- Mounts `bootstrap.sh` and `config/` read-only.
- Listed in `ignore_services` in `komodo/apps.toml`, like `register`.

`bootstrap.sh` runs on every deploy, stops on the first failed call, and never prints a secret:

1. For each key in `settings.json`, read the live value and write it only if it differs.
2. Create each user in `users.json` that does not exist. Set `admin@windmill.dev`'s password to `WINDMILL_ADMIN_PASSWORD`, because a fresh database creates it with the default password `changeme`.
3. Mint a 15-minute token impersonating the workspace owner. Content and the git sync variable are then owned by the owner, as they are today, rather than by the superadmin-secret identity, which Windmill refuses as a schedule's `on_behalf_of`.
4. Create the `homelab` workspace if it does not exist, with the owner as its admin.
5. Only if step 4 created the workspace: clone `homelab-windmill` main (public, no credential), `npm ci` so the repo's pinned CLI is used, and `wmill sync push` into the new workspace. Git sync is configured after this step, so seeding does not trigger commits.
6. Write the secret variable `f/git_sync/repo_url` as `https://x-access-token:<PAT>@github.com/algebananazzzzz/homelab-windmill.git`, only if its value differs. A `$var:` reference must be a whole field value, so the variable holds the full URL. The `f/git_sync` folder comes from the content, so on an existing workspace the content must already be deployed.
7. Apply `git_sync.json` with `edit_git_sync_config`.

### Komodo stack config

- `environment` adds `SUPERADMIN_SECRET='[[WINDMILL_SUPERADMIN_SECRET]]'`, `WINDMILL_OIDC_CLIENT_SECRET='[[WINDMILL_OIDC_CLIENT_SECRET]]'`, `WINDMILL_ADMIN_PASSWORD='[[WINDMILL_ADMIN_PASSWORD]]'` and `WINDMILL_GIT_SYNC_TOKEN='[[WINDMILL_GIT_SYNC_TOKEN]]'`, single-quoted as the other stacks are.
- `ignore_services` adds `bootstrap`.
- `config_files` adds `bootstrap.sh` and the four `config/` files, so a change to them redeploys the stack.
- `post_deploy` waits for `bootstrap`, prints its log into the deploy log, and fails the deploy if it exited non-zero. Without it a failed bootstrap would be invisible: nothing depends on it and it is in `ignore_services`.

## homelab-windmill changes

### Git sync content

- `f/git_sync/folder.meta.yaml` and `f/git_sync/homelab_windmill.resource.yaml`, a `git_repository` resource whose `url` is `$var:f/git_sync/repo_url` and whose branch is `main`. It passes the existing plain-text credential check.
- Windmill commits each deploy made in Windmill to main with a `[WM]` prefix. Git sync is available on Community Edition for workspaces with up to 2 users; `homelab` has one.
- `wmill.yaml` keeps governing what the CLI syncs. `config/git_sync.json` in `homelab-komodo` governs what git sync commits. If they disagree, the nightly drift comparison shows it.

### `sync.yml`

The `deploy` job is skipped when the head commit message starts with `[WM]`, because that content is already live.

### `drift.yml`

- Keeps the `wmill sync pull --dry-run` comparison. A difference now means git sync failed, and the error message says so.
- Adds `scripts/check-vars.sh`: every `$var:<path>` reference under `f/` must exist as a variable in the workspace. Missing ones are listed and fail the job. After a rebuild, this list is the set of secrets to re-enter.

## Recovery runbook (empty `windmill` database)

1. Deploy the Windmill stack in Komodo, or run the `cold-start` procedure. The bootstrap restores the managed settings and users, creates the `homelab` workspace, seeds the content from `homelab-windmill` main, and configures git sync.
2. Sign in through Authelia, mint an API token and update `WMILL_TOKEN` in the `homelab-windmill` GitHub secrets.
3. Run the `drift` workflow. Re-enter each secret it lists in the Windmill UI, then run it again until it passes.
4. Mint new tokens for any MCP client that talks to Windmill.

Break-glass if Authelia is down: with `SUPERADMIN_SECRET`, `POST /api/settings/global/disable_password_login` with `{"value": null}` re-enables password login for `admin@windmill.dev`. The next deploy turns it off again.

## Security notes

- Komodo already holds `POSTGRES_PASSWORD`, a superuser on the shared cluster, so the new variables do not add a party who can read Windmill's secrets.
- `SUPERADMIN_SECRET` is a static, non-expiring superadmin token on a public instance. It is long and random, never reaches the worker, and is rotated by changing the Komodo variable and redeploying.
- The existing weakness remains and is worse: any script can read the worker's `DATABASE_URL`, which is the Postgres superuser.

## Risks verified during implementation

- **Echo commits.** A CI deploy may trigger git sync to commit the same content back. If Windmill re-serializes files so they differ, the result is noise commits. Check on the live rollout; if they occur, decide between excluding CI deploys from git sync and normalizing the repo to Windmill's serialization.
- **Silent git sync failure.** If a git sync commit fails, the next CI push deletes the unsynced item. Deleted items stay recoverable with `wmill trash` for three days, and the nightly drift job reports the gap.
- **Push races.** A `[WM]` commit landing while a PR is open is an ordinary concurrent change on main. A direct push to main that is behind is rejected by GitHub as non-fast-forward.

## Testing

1. A throwaway stack on svc-apps-02 with its own empty Postgres container, the pinned Windmill image, and the real `bootstrap` service and `config/`, using dummy secrets. Check that the managed settings match `settings.json`, the users exist, the `homelab` workspace exists with the owner as admin, `f/kaneo` and its schedule were seeded, the git sync variable is set, and the git sync settings match `git_sync.json`.
2. Run the bootstrap a second time and confirm it writes no settings and does not re-seed. Run `check-vars.sh` against the throwaway instance and confirm it reports `f/kaneo/api_key` as missing.
3. Only after both pass, deploy to the live instance, make a UI edit, and confirm a `[WM]` commit reaches main and CI skips it.
