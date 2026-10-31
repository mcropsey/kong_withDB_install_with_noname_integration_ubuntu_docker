#!/usr/bin/env bash
# Recreate the rootful-Podman "kong" container from a given image, keeping the DB-mode
# settings, and roll back to the previous image automatically if the Admin API doesn't come back.
#
#   ./kong-recreate-podman.sh kong-noname:3.6-5.0.2      # switch to a new Noname build
#   ./kong-recreate-podman.sh kong-noname:3.6-5.0.1      # roll back to the previous build
#   PLUGINS=bundled ./kong-recreate-podman.sh docker.io/library/kong:3.6   # stock image (remove the
#                                                         # nonamesecurity entry from kong.yaml + apply FIRST)
#
# Env overrides:
#   PW_FILE   DB password file (default /opt/kong/kong-db-password if it exists, else ~/.kong-db-password)
#   PLUGINS   KONG_PLUGINS value (default bundled,nonamesecurity)
set -euo pipefail

NEW=${1:?usage: $0 <image>}
PLUGINS=${PLUGINS:-bundled,nonamesecurity}
if [ -z "${PW_FILE:-}" ]; then
  if sudo test -f /opt/kong/kong-db-password; then PW_FILE=/opt/kong/kong-db-password; else PW_FILE=$HOME/.kong-db-password; fi
fi
PW=$(sudo cat "$PW_FILE" | tr -d '[:space:]')
[ ${#PW} -ge 16 ] || { echo "could not read DB password from $PW_FILE" >&2; exit 1; }
sudo podman image exists "$NEW" || { echo "image $NEW not found (build it first)" >&2; exit 1; }

OLD=$(sudo podman inspect kong --format '{{.ImageName}}' 2>/dev/null || true)
OLD_PLUGINS=$(sudo podman inspect kong --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                | sed -n 's/^KONG_PLUGINS=//p')
OLD_PLUGINS=${OLD_PLUGINS:-bundled}   # no KONG_PLUGINS on the old container = Kong's default
OLD_MOUNTS=$(sudo podman inspect kong --format '{{range .Mounts}}-v {{.Source}}:{{.Destination}}:ro {{end}}' 2>/dev/null || true)

run_kong() {  # run_kong <image> <plugins> [extra args...]
  local img=$1 plugins=$2; shift 2
  sudo podman run -d --name kong --network kongnet --restart unless-stopped \
    -p 80:8000 -p 8001:8001 \
    -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-db -e KONG_PG_USER=kong \
    -e KONG_PG_PASSWORD="$PW" -e KONG_PG_DATABASE=kong \
    -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
    -e KONG_PLUGINS="$plugins" "$@" "$img" >/dev/null
}

echo "kong: ${OLD:-<none>} -> $NEW  (KONG_PLUGINS=$PLUGINS)"
sudo podman rm -f kong >/dev/null 2>&1 || true
run_kong "$NEW" "$PLUGINS"

for _ in $(seq 1 30); do
  if curl -s -m 2 -o /dev/null http://localhost:8001/status; then
    sleep 5
    echo "up: $(sudo podman ps --filter name='^kong$' --format '{{.Image}}  {{.Status}}')"
    curl -s http://localhost:8001/ | python3 -c 'import json,sys; print("enabled plugins:", json.load(sys.stdin)["plugins"]["enabled_in_cluster"])'
    exit 0
  fi
  sleep 2
done

echo "!!! Admin API did not come back on $NEW. Last log lines:" >&2
sudo podman logs --tail 20 kong >&2 || true
[ -n "$OLD" ] || exit 1
echo "!!! rolling back to $OLD" >&2
sudo podman rm -f kong >/dev/null
# shellcheck disable=SC2086  # OLD_MOUNTS is intentionally word-split into -v args
run_kong "$OLD" "$OLD_PLUGINS" $OLD_MOUNTS
exit 1
