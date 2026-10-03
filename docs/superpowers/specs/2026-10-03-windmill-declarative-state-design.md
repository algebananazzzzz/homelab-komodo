# Windmill declarative state

## Goal

If the `windmill` database is lost, Windmill can be rebuilt to a working state from git and Komodo variables plus a short manual runbook. Changes flow both ways: a push to `homelab-windmill` deploys to Windmill, and a change made in Windmill (UI, MCP agent, API) lands on `homelab-windmill` main.

Out of scope: job history, run logs and the audit log. A future dump routine will cover those. Its output holds the secrets and the workspace key that decrypts them, so its destination must be treated as secret storage.

## Layers and ownership

| Layer | Source of truth | Applied by |
|---|---|---|
| Instance settings and worker groups | `homelab-komodo` `stacks/apps/windmill/config/windmill-config.yaml` | `config_sync` service (`windmill sync-config`) on every Komodo deploy |
| Workspace existence | `homelab-windmill` CI (`wmill workspace add --create`) | CI on every push to main; a no-op unless the workspace is gone |
| Workspace settings, including the git sync config | `homelab-windmill` `settings.yaml` (`includeSettings: true`) | CI's `wmill sync push`; git sync commits changes made in Windmill |
| Workspace content | `homelab-windmill` `f/**` | CI's `wmill sync push`; git sync commits changes made in Windmill |
| Git sync URL secret | GitHub secret `WINDMILL_GIT_SYNC_TOKEN` on `homelab-windmill` | CI's `wmill variable add` after the push |
| Other workspace secret values | Not stored | Re-entered by hand, listed by `check-vars.sh` |
| API tokens (GitHub CI, MCP clients) | Not stored | Re-issued by hand after a rebuild |
| Superadmin flag on your account | Not stored | Set by hand after a rebuild |

Workspace secrets are not mirrored anywhere. Most are keys issued by other homelab apps whose state lives in the same Postgres cluster, so the outages that lose Windmill's database usually invalidate them anyway.

## homelab-komodo

`config/windmill-config.yaml` is Windmill's instance config format, applied by `windmill sync-config` from the pinned Windmill image with `DATABASE_URL`. It declares `base_url`, the Authelia OAuth client (secret as `envRef: WINDMILL_OIDC_CLIENT_SECRET`), `disable_password_login: true`, `require_preexisting_user_for_oauth: false`, `automate_username_creation`, `custom_tags`, and the `default`, `native` and `reports` worker groups. It runs in Replace mode: settings and worker groups missing from the file are deleted, except the ones Windmill generates and protects (`jwt_secret`, `uid`, the custom instance Postgres passwords, and others in `PROTECTED_SETTINGS`), so those never go in git.

`sync-config` does not create tables, so on an empty database it must run after the server's first start. Compose order: `register`, then `server` until healthy, then `config_sync`, then `worker`. A failed sync leaves the worker unstarted and fails the Komodo deploy.

With `require_preexisting_user_for_oauth: false`, the first Authelia login creates the account, so no user setup is needed. The account is not a superadmin, so the server sets `CREATE_WORKSPACE_REQUIRE_SUPERADMIN=false` and `homelab-windmill` CI can create the workspace with that account's token.

## homelab-windmill

- `wmill.yaml` sets `includeSettings: true`, so `settings.yaml` (pulled with `wmill sync pull --include-settings`) carries the workspace settings and the git sync repository entry. Git sync's object types include `settings`, so a settings change made in the UI is committed too.
- `f/git_sync/homelab_windmill.resource.yaml` is the `git_repository` resource git sync pushes through. Its `url` is `$var:f/git_sync/repo_url`, a secret variable holding `https://x-access-token:<PAT>@github.com/algebananazzzzz/homelab-windmill.git`, with a fine-grained PAT limited to this repo's contents.
- `sync.yml` creates the workspace if missing, runs `wmill sync push`, then writes `f/git_sync/repo_url` with `wmill variable add` from the `WINDMILL_GIT_SYNC_TOKEN` GitHub secret. It skips commits whose message starts with `[WM]`, which git sync writes after the change is already live.
- `drift.yml` runs nightly: `wmill sync pull --dry-run` must show no difference (a difference means git sync failed), and `scripts/check-vars.sh` lists every `$var:` reference with no variable.

## Recovery runbook (empty `windmill` database)

1. Deploy the Windmill stack in Komodo, or run `cold-start`. `config_sync` restores the instance settings and worker groups.
2. Sign in through Authelia, which creates your account. If you want superadmin, set it yourself.
3. Mint an API token and update `WMILL_TOKEN` in the `homelab-windmill` GitHub secrets.
4. Re-run the latest `sync` workflow on main. It creates the `homelab` workspace with you as admin, pushes the settings, git sync config and content, and writes the git sync URL.
5. Run the `drift` workflow and re-enter each secret it lists.
6. Mint new tokens for any MCP client that talks to Windmill.

Break-glass if Authelia is down: delete the `disable_password_login` row from `global_settings` in the `windmill` database and log in as `admin@windmill.dev`. The next deploy turns password login off again.

## Known behavior

- Windmill's folder update treats `summary: null` as unchanged, so clearing a summary from the repo does not take, and git sync commits Windmill's value back.
- Git sync orders some YAML keys differently from the CLI (`owners` after `extra_perms`), so its first commit to a file can include a reorder.
- If a git sync commit fails, the next CI push deletes the unsynced item. Deleted items stay recoverable with `wmill trash` for three days, and the nightly drift job reports the gap.
- Any script can read the worker's `DATABASE_URL`, which is the Postgres superuser. The fix is a dedicated role that owns only the `windmill` database.
