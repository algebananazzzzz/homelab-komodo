#!/usr/bin/env python3
"""Mint or revoke a temporary OpenBao root token from the unseal key, for changing app secrets.

OpenBao 2.7 only allows this while the tcp listener sets disable_unauthed_generate_root_endpoints = false,
so turn that on in stacks/secrets/openbao/config/openbao.hcl, redeploy, unseal, run `mint`, make the change,
run `revoke`, then turn it off again. The token is kept in ~/.config/homelab/openbao-root-token and never printed.
"""
import base64
import http.client
import json
import os
import ssl
import sys

HOME = os.path.expanduser("~")
INIT = f"{HOME}/.config/homelab/openbao-init.json"
TOKEN_FILE = f"{HOME}/.config/homelab/openbao-root-token"
CA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "openbao.crt")


def bao(method, path, body=None, token=None):
    ctx = ssl.create_default_context(cafile=CA)
    # The committed self-signed certificate is the only trust anchor; it names openbao.service.consul, not the IP.
    ctx.check_hostname = False
    conn = http.client.HTTPSConnection("10.10.20.112", 8200, context=ctx, timeout=30)
    conn.request(method, f"/v1/{path}", body=None if body is None else json.dumps(body),
                 headers={"X-Vault-Token": token} if token else {})
    resp = conn.getresponse()
    text = resp.read().decode()
    if resp.status >= 400:
        # Error bodies can echo request data, so only the status is shown.
        sys.exit(f"{method} {path}: HTTP {resp.status}")
    return json.loads(text) if text else {}


def mint():
    if os.path.exists(TOKEN_FILE):
        sys.exit("a temporary root token already exists; revoke it first")
    key = json.load(open(INIT))["unseal_keys_b64"][0]
    bao("DELETE", "sys/generate-root/attempt")
    attempt = bao("PUT", "sys/generate-root/attempt", {})
    done = bao("PUT", "sys/generate-root/update", {"key": key, "nonce": attempt["nonce"]})
    if not done["complete"]:
        sys.exit("generate-root did not complete")
    encoded = done["encoded_token"]
    raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4))
    root = bytes(a ^ b for a, b in zip(raw, attempt["otp"].encode())).decode()
    if bao("GET", "auth/token/lookup-self", token=root)["data"]["policies"] != ["root"]:
        sys.exit("the decoded token is not a root token")
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(root)
    print("temporary root token minted")


def revoke():
    bao("POST", "auth/token/revoke-self", {}, token=open(TOKEN_FILE).read())
    os.remove(TOKEN_FILE)
    print("temporary root token revoked")


{"mint": mint, "revoke": revoke}[sys.argv[1]]()
