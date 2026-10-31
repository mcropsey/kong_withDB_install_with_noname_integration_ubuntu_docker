#!/usr/bin/env bash
# Creates the 9 services + 9 routes + 9 rate-limiting plugins via the Kong Admin API.
# Same config as Step 8 of the guide. Run on the Kong host: ./configure-kong.sh
# Override the Admin API with ADMIN=http://host:8001 ./configure-kong.sh
set -euo pipefail
ADMIN=${ADMIN:-http://localhost:8001}

RL='{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'

# service        upstream-host   port   route-name        route-host
APPS="
crapi-app      192.168.1.101   8888   crapi-root        crapi.cropseyit.com
crapi-mail     192.168.1.101   8025   crapi-mailhog     mail.cropseyit.com
dvga           192.168.1.101   5013   dvga-root         dvga.cropseyit.com
jenkins        192.168.1.100   8080   jenkins-root      jenkins.cropseyit.com
juice-nomon    192.168.1.99    30300  juice-nomon-root  juice-nomon.cropseyit.com
juice-shop     192.168.1.101   3000   juice-root        juice.cropseyit.com
k8s            192.168.1.75    80     k8s-root          k8s.cropseyit.com
notes          192.168.1.98    8000   notes-root        notes.cropseyit.com
vampi          192.168.1.99    30500  vampi-root        vampi.cropseyit.com
"

post() {  # post <path> <json>; fails loudly on anything but 201
  local code
  code=$(curl -s -o /tmp/kong-post.$$ -w '%{http_code}' -X POST "$ADMIN$1" \
           -H 'Content-Type: application/json' -d "$2")
  if [ "$code" != 201 ]; then
    echo "POST $1 failed ($code): $(cat /tmp/kong-post.$$)" >&2; rm -f /tmp/kong-post.$$; exit 1
  fi
  rm -f /tmp/kong-post.$$
}

echo "$APPS" | while read -r svc host port route rhost; do
  [ -z "$svc" ] && continue
  post /services "{\"name\":\"$svc\",\"host\":\"$host\",\"port\":$port,\"protocol\":\"http\",\"connect_timeout\":60000}"
  post "/services/$svc/routes" "{\"name\":\"$route\",\"hosts\":[\"$rhost\"],\"paths\":[\"/\"],\"strip_path\":false,\"preserve_host\":true}"
  post "/services/$svc/plugins" "$RL"
  echo "ok  $svc  ->  $host:$port  ($rhost)"
done
