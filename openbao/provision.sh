#!/bin/sh
# Creates the KV mount, the apps policy and AppRole, and the Authelia OIDC login. Safe to rerun.
# Reads a token with sudo-level OpenBao rights on stdin and prints the AppRole credentials as JSON.
# The OIDC login reads its client secret from kv/admin/openbao-oidc (CLIENT_SECRET), outside what the apps policy can read.
set -eu

read -r BAO_TOKEN
export BAO_TOKEN
bao() { docker exec -i -e BAO_TOKEN openbao bao "$@"; }

bao secrets list -format=json | grep -q '"kv/"' || bao secrets enable -path=kv -version=2 kv >/dev/null
bao auth list -format=json | grep -q '"approle/"' || bao auth enable approle >/dev/null
bao policy write apps - < "$(dirname "$0")/apps-policy.hcl" >/dev/null
bao write auth/approle/role/apps token_policies=apps token_ttl=5m token_max_ttl=15m secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

bao auth list -format=json | grep -q '"oidc/"' || bao auth enable oidc >/dev/null
bao policy write admin - < "$(dirname "$0")/admin-policy.hcl" >/dev/null
# Authelia's hostname resolves to Traefik, whose certificate the homelab CA signs. JSON on stdin keeps the secret out of the process list.
CLIENT_SECRET=$(bao kv get -field=CLIENT_SECRET kv/admin/openbao-oidc) python3 -c '
import json, os
print(json.dumps({
    "oidc_discovery_url": "https://auth.algebananazzzzz.com",
    "oidc_discovery_ca_pem": open("/usr/local/share/ca-certificates/homelab-ca.crt").read(),
    "oidc_client_id": "openbao",
    "oidc_client_secret": os.environ["CLIENT_SECRET"],
    "default_role": "admin",
}))' | bao write auth/oidc/config - >/dev/null
bao write auth/oidc/role/admin role_type=oidc user_claim=preferred_username bound_audiences=openbao \
  allowed_redirect_uris=https://openbao.ops.home.arpa/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback \
  oidc_scopes=profile,email token_policies=admin token_ttl=8h >/dev/null

role_id=$(bao read -field=role_id auth/approle/role/apps/role-id)
if [ "${1:-}" = "--new-secret-id" ]; then
  secret_id=$(bao write -f -field=secret_id auth/approle/role/apps/secret-id)
  printf '{"OPENBAO_ROLE_ID": "%s", "OPENBAO_SECRET_ID": "%s"}\n' "$role_id" "$secret_id"
else
  printf '{"OPENBAO_ROLE_ID": "%s"}\n' "$role_id"
fi
