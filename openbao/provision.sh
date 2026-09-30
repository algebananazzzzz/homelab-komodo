#!/bin/sh
# Creates the KV mount, the apps policy and the apps AppRole. Safe to rerun.
# Reads a token with sudo-level OpenBao rights on stdin and prints the AppRole credentials as JSON.
set -eu

read -r BAO_TOKEN
export BAO_TOKEN
bao() { docker exec -i -e BAO_TOKEN openbao bao "$@"; }

bao secrets list -format=json | grep -q '"kv/"' || bao secrets enable -path=kv -version=2 kv >/dev/null
bao auth list -format=json | grep -q '"approle/"' || bao auth enable approle >/dev/null
bao policy write apps - < "$(dirname "$0")/apps-policy.hcl" >/dev/null
bao write auth/approle/role/apps token_policies=apps token_ttl=5m token_max_ttl=15m secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

role_id=$(bao read -field=role_id auth/approle/role/apps/role-id)
if [ "${1:-}" = "--new-secret-id" ]; then
  secret_id=$(bao write -f -field=secret_id auth/approle/role/apps/secret-id)
  printf '{"OPENBAO_ROLE_ID": "%s", "OPENBAO_SECRET_ID": "%s"}\n' "$role_id" "$secret_id"
else
  printf '{"OPENBAO_ROLE_ID": "%s"}\n' "$role_id"
fi
