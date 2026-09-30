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
}
