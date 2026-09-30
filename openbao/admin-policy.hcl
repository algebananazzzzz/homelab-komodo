# Granted to every Authelia login over OIDC. danielz is the only Authelia user and holds root-equivalent rights,
# so the root token is needed only while Authelia is down.
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
