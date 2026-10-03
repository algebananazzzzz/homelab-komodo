# Windmill declarative state

## Goal

If the `windmill` database is lost, Windmill can be rebuilt to a working state from git and Komodo variables plus a short manual runbook. Changes flow both ways: a push to `homelab-windmill` deploys to Windmill, and a change made in Windmill (UI, MCP agent, API) lands on `homelab-windmill` main.

Out of scope: job history, run logs and the audit log. A future dump routine will cover those. Its output holds the secrets and the workspace key that decrypts them, so its destination must be treated as secret storage.

## Layers and ownership

| Layer | Source of truth | Applied by |
|---|---|---|
| Instance settings needed to sign in, and the users | `homelab-komodo` `stacks/apps/windmill/config/` | `bootstrap` service on every Komodo deploy |
| Workspace existence | `homelab-windmill` CI (`wmill workspace add --create`) | CI on every push to main; a no-op unless the workspace is gone |
| Workspace settings, including the git sync config | `homelab-windmill` `settings.yaml` (`includeSettings: true`) | CI's `wmill sync push`; git sync commits changes made in Windmill |
| Workspace content | `homelab-windmill` `f/**` | CI's `wmill sync push`; git sync commits changes made in Windmill |
| Workspace secret values, including the git sync URL | Not stored | Re-entered by hand, listed by `check-vars.sh` |
| API tokens (GitHub CI, MCP clients) | Not stored | Re-issued by hand after a rebuild |

Workspace secrets are not mirrored anywhere. Most are keys issued by other homelab apps whose state lives in the same Postgres cluster, so the outages that lose Windmill's database usually invalidate them anyway.

## Why instance settings are not synced with `wmill instance push`

`wmill instance push` treats its file as the complete instance: every global setting missing from `instance_settings.yaml` is set to null. Using it means committing every setting, including `jwt_secret` and two generated Postgres passwords (`custom_instance_pg_databases.user_pwd`, `custom_instance_replication_pwd`) that the CLI does not encrypt, and both repos are public. Its users step also calls `POST /users/overwrite`, which is Enterprise-only. Windmill regenerates those secrets on a fresh database, so they do not need to be in git. The bootstrap sets only the four settings that signing in depends on, through the REST API.

## homelab-komodo

### `stacks/apps/windmill/config/`

- `settings.json`: `base_url`, `oauths`, `disable_password_login`, `require_preexisting_user_for_oauth`, copied from the live instance. A string `env:NAME` is replaced with that environment variable; that is how the OIDC client secret gets in, and an unset variable fails the run.
- `users.json`: users to create if missing, in the `POST /api/users/create` body format. Today: `daniel.zhouqx@gmail.com`, superadmin, login type `pending_oauth`, so the first Authelia login adopts the account. Login type `authelia` fails on a fresh database because Windmill loads a newly set OAuth client a few seconds later.

### `bootstrap` service

A one-shot `alpine` service in `compose.yml` that installs `curl` and `jq` and runs `bootstrap.sh` after `server` is healthy. It authenticates with Windmill's `SUPERADMIN_SECRET` env var, which acts as a superadmin bearer token that lives outside the database, so it works against an empty database. The secret goes to `server` and `bootstrap` only, never `worker`, so scripts cannot read it.

`bootstrap.sh` writes each declared setting whose live value differs, creates each missing user, and stops on the first failed call with the response body on stderr.

### Komodo stack config

- `environment`: `SUPERADMIN_SECRET='[[WINDMILL_SUPERADMIN_SECRET]]'` and `WINDMILL_OIDC_CLIENT_SECRET='[[WINDMILL_OIDC_CLIENT_SECRET]]'`.
- `ignore_services` includes `bootstrap`; `config_files` lists `bootstrap.sh` and both `config/` files.
- `post_deploy` waits for `bootstrap`, prints its log into the deploy log, and fails the deploy if it exited non-zero.

## homelab-windmill

- `wmill.yaml` sets `includeSettings: true`, so `settings.yaml` (pulled with `wmill sync pull --include-settings`) carries the workspace settings and the git sync repository entry. Git sync's object types include `settings`, so a settings change made in the UI is committed too.
- `f/git_sync/homelab_windmill.resource.yaml` is the `git_repository` resource git sync pushes through. Its `url` is `$var:f/git_sync/repo_url`, a secret variable holding `https://x-access-token:<PAT>@github.com/algebananazzzzz/homelab-windmill.git`, with a fine-grained PAT limited to this repo's contents.
- `sync.yml` creates the workspace if missing, then runs `wmill sync push`. It skips commits whose message starts with `[WM]`, which git sync writes after the change is already live.
- `drift.yml` runs nightly: `wmill sync pull --dry-run` must show no difference (a difference means git sync failed), and `scripts/check-vars.sh` lists every `$var:` reference with no variable.

## Recovery runbook (empty `windmill` database)

1. Deploy the Windmill stack in Komodo, or run `cold-start`. The bootstrap restores the sign-in settings and your user.
2. Sign in through Authelia, mint an API token and update `WMILL_TOKEN` in the `homelab-windmill` GitHub secrets.
3. Re-run the latest `sync` workflow on main. It creates the `homelab` workspace with you as admin and pushes the settings, git sync config and content.
4. Run the `drift` workflow and re-enter each secret it lists, including `f/git_sync/repo_url`.
5. Mint new tokens for any MCP client that talks to Windmill.

Break-glass if Authelia is down: with `SUPERADMIN_SECRET`, `POST /api/settings/global/disable_password_login` with `{"value": null}` re-enables password login for `admin@windmill.dev`. The next deploy turns it off again.

## Known behavior

- Windmill's folder update treats `summary: null` as unchanged, so clearing a summary from the repo does not take, and git sync commits Windmill's value back.
- Git sync orders some YAML keys differently from the CLI (`owners` after `extra_perms`), so its first commit to a file can include a reorder.
- If a git sync commit fails, the next CI push deletes the unsynced item. Deleted items stay recoverable with `wmill trash` for three days, and the nightly drift job reports the gap.
- Any script can read the worker's `DATABASE_URL`, which is the Postgres superuser. The fix is a dedicated role that owns only the `windmill` database.
