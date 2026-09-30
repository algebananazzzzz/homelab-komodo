# One login for every app stack for now; a per-app split is in the spec's Deferred hardening.
path "kv/data/apps/*" {
  capabilities = ["read"]
}
