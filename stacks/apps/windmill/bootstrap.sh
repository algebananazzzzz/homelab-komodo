#!/bin/sh
set -euo pipefail

api() {
  method=$1 path=$2
  shift 2
  if ! response=$(curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $SUPERADMIN_SECRET" -H 'Content-Type: application/json' "$@" "$WM_URL/api$path"); then
    echo "$method $path failed: $response" >&2
    return 1
  fi
  printf '%s' "$response"
}

# Only the declared keys are managed. wmill instance push would clear every setting missing from its file, so it would need jwt_secret and the generated database passwords committed.
jq -c 'walk(if type == "string" and startswith("env:") then ($ENV[.[4:]] // error("\(.[4:]) is not set")) else . end) | to_entries[]' /config/settings.json >/tmp/settings
while read -r entry; do
  key=$(printf '%s' "$entry" | jq -r .key)
  have=$(api GET "/settings/global/$key" | jq -cS .)
  if [ "$have" != "$(printf '%s' "$entry" | jq -cS .value)" ]; then
    printf '%s' "$entry" | jq -c '{value}' | api POST "/settings/global/$key" --data-binary @- >/dev/null
    echo "set $key"
  fi
done </tmp/settings

jq -c '.[]' /config/users.json >/tmp/users
while read -r user; do
  email=$(printf '%s' "$user" | jq -r .email)
  exists=$(api GET "/users/exists/$email")
  if [ "$exists" != true ]; then
    printf '%s' "$user" | api POST /users/create --data-binary @- >/dev/null
    echo "created user $email"
  fi
done </tmp/users

echo "bootstrap done"
