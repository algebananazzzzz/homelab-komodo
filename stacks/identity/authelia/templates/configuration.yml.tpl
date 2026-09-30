{{- with secret "kv/data/apps/authelia" -}}
---
server:
  address: 'tcp://:9091'
  endpoints:
    authz:
      forward-auth:
        implementation: 'ForwardAuth'

log:
  level: 'info'

totp:
  issuer: 'home.arpa'

authentication_backend:
  file:
    path: '/config/users_database.yml'
    password:
      algorithm: 'argon2'
      argon2:
        variant: 'argon2id'
        iterations: 3
        memory: 65536
        parallelism: 4
        key_length: 32
        salt_length: 16

access_control:
  default_policy: 'deny'
  rules:
    - domain: 'auth.home.arpa'
      policy: 'bypass'
    - domain: 'home.arpa'
      policy: 'one_factor'
    - domain: '*.svc.home.arpa'
      policy: 'one_factor'
    - domain: '*.ops.home.arpa'
      policy: 'one_factor'
    - domain: '*.algebananazzzzz.com'
      policy: 'one_factor'

session:
  secret: {{ .Data.data.SESSION_SECRET | toJSON }}
  cookies:
    - domain: 'auth.home.arpa'
      authelia_url: 'https://auth.home.arpa'
      default_redirection_url: 'https://auth.home.arpa/'
      expiration: '1h'
      inactivity: '5m'
    - domain: 'algebananazzzzz.com'
      authelia_url: 'https://auth.algebananazzzzz.com'
      default_redirection_url: 'https://auth.algebananazzzzz.com/'
      expiration: '1h'
      inactivity: '5m'
  redis:
    host: 'redis.service.consul'
    port: 6379
    password: {{ .Data.data.REDIS_PASSWORD | toJSON }}

regulation:
  max_retries: 3
  find_time: '2m'
  ban_time: '5m'

storage:
  encryption_key: {{ .Data.data.STORAGE_ENCRYPTION_KEY | toJSON }}
  postgres:
    address: 'tcp://postgres.service.consul:5432'
    database: 'authelia'
    schema: 'public'
    username: 'admin'
    password: {{ .Data.data.POSTGRES_PASSWORD | toJSON }}

identity_validation:
  reset_password:
    jwt_secret: {{ .Data.data.JWT_SECRET | toJSON }}

notifier:
  disable_startup_check: false
  filesystem:
    filename: '/config/notification.txt'

identity_providers:
  oidc:
    hmac_secret: {{ .Data.data.OIDC_HMAC_SECRET | toJSON }}
    jwks:
      - key_id: 'main-2026-09-30'
        algorithm: 'RS256'
        use: 'sig'
        key: {{ .Data.data.OIDC_JWKS_KEY | toJSON }}
    # Komodo and OpenBao name the user from the ID token alone, which Authelia keeps minimal unless told otherwise.
    claims_policies:
      id_token_profile:
        id_token:
          - 'preferred_username'
          - 'email'
          - 'name'
    clients:
      - client_id: 'outline'
        client_name: 'Outline'
        client_secret: {{ .Data.data.OUTLINE_CLIENT_SECRET_DIGEST | toJSON }}
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        require_pkce: false
        redirect_uris:
          - 'https://outline.algebananazzzzz.com/auth/oidc.callback'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        token_endpoint_auth_method: 'client_secret_post'
        userinfo_signed_response_alg: 'none'
      - client_id: 'kaneo'
        client_name: 'Kaneo'
        client_secret: {{ .Data.data.KANEO_CLIENT_SECRET_DIGEST | toJSON }}
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        require_pkce: false
        redirect_uris:
          - 'https://kaneo.algebananazzzzz.com/api/auth/oauth2/callback/custom'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        token_endpoint_auth_method: 'client_secret_post'
        userinfo_signed_response_alg: 'none'
      - client_id: 'komodo'
        client_name: 'Komodo'
        client_secret: {{ .Data.data.KOMODO_CLIENT_SECRET_DIGEST | toJSON }}
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        claims_policy: 'id_token_profile'
        require_pkce: true
        pkce_challenge_method: 'S256'
        redirect_uris:
          - 'https://komodo.ops.home.arpa/auth/oidc/callback'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        token_endpoint_auth_method: 'client_secret_basic'
        userinfo_signed_response_alg: 'none'
      - client_id: 'openbao'
        client_name: 'OpenBao'
        client_secret: {{ .Data.data.OPENBAO_CLIENT_SECRET_DIGEST | toJSON }}
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        claims_policy: 'id_token_profile'
        require_pkce: false
        # The second URI is the `bao login -method=oidc` listener on the workstation.
        redirect_uris:
          - 'https://openbao.ops.home.arpa/ui/vault/auth/oidc/oidc/callback'
          - 'http://localhost:8250/oidc/callback'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        token_endpoint_auth_method: 'client_secret_basic'
        userinfo_signed_response_alg: 'none'
{{ end -}}
