{{- with secret "kv/data/apps/authelia" -}}
---
users:
  danielz:
    disabled: false
    displayname: 'Daniel'
    password: {{ .Data.data.USER_PASSWORD_DIGEST | toJSON }}
    email: 'daniel.zhouqx@gmail.com'
    groups:
      - 'admins'
{{ end -}}
