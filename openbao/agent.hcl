# Log in once, render, and exit, so the app starts only after its secrets exist.
exit_after_auth = true

vault {
  address = "https://openbao.service.consul:8200"
  ca_cert = "/openbao/ca.crt"

  retry {
    num_retries = 3
  }
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/run/secrets/openbao_role_id"
      secret_id_file_path                 = "/run/secrets/openbao_secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

# A missing secret must stop the stack, never start the app with an empty file.
template_config {
  exit_on_retry_failure = true
}

# Every key under kv/apps/<APP>, single-quoted so `set -a; . /secrets/app.env` keeps the value literal.
template {
  destination          = "/secrets/app.env"
  perms                = "0644"
  error_on_missing_key = true
  contents             = <<-EOT
    {{- with secret (printf "kv/data/apps/%s" (env "APP")) }}
    {{- range $key, $value := .Data.data }}
    {{ $key }}='{{ $value | replaceAll "'" "'\\''" }}'
    {{- end }}
    {{- end }}
  EOT
}
