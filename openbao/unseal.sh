#!/bin/sh
# Unseals OpenBao after a restart. The key goes over TLS on stdin, so it never shows in a process list or output.
set -eu
cert="$(dirname "$0")/openbao.crt"
python3 -c 'import json, os; print(json.dumps({"key": json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["unseal_keys_b64"][0]}))' \
  | curl -s --cacert "$cert" --resolve openbao.service.consul:8200:10.10.20.112 \
      -X PUT --data-binary @- https://openbao.service.consul:8200/v1/sys/unseal \
  | python3 -c 'import json, sys; print("sealed" if json.load(sys.stdin)["sealed"] else "unsealed")'
