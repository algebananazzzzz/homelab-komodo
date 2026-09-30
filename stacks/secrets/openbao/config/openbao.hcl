ui           = true
api_addr     = "https://openbao.service.consul:8200"
cluster_addr = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/tls/cert.pem"
  tls_key_file  = "/openbao/tls/key.pem"

  # Temporarily on so the unseal key alone can mint a root token; phase 3 turns it back off.
  disable_unauthed_generate_root_endpoints = false
}
