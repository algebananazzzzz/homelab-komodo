#!/bin/sh
# Brings a Windmill instance, empty or not, to the state declared in /config. Runs on every deploy of the stack.
set -euo pipefail

CONTENT_REPO=algebananazzzzz/homelab-windmill
URL_VARIABLE=f/git_sync/repo_url

api() {
  token=$1 method=$2 path=$3
  shift 3
  # Callers discard stdout, so a failure's response body goes to stderr where the deploy log shows it.
  if ! response=$(curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' "$@" "$WM_URL/api$path"); then
    echo "$method $path failed: $response" >&2
    return 1
  fi
  printf '%s' "$response"
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
  jq '{id, name}' /config/workspace.json | as_owner POST /workspaces/create --data-binary @- >/dev/null
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
