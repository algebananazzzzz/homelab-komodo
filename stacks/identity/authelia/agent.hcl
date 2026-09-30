# Authelia reads whole files, so its agent renders them instead of the shared app.env.
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

# A missing secret must stop the stack, never start Authelia with a partial file.
template_config {
  exit_on_retry_failure = true
}

template {
  source               = "/openbao/templates/configuration.yml.tpl"
  destination          = "/config/configuration.yml"
  perms                = "0600"
  error_on_missing_key = true
}

template {
  source               = "/openbao/templates/users_database.yml.tpl"
  destination          = "/config/users_database.yml"
  perms                = "0600"
  error_on_missing_key = true
}
