# Kong Install Guide — Ubuntu 24.04 + Docker (DB Mode, from scratch)

Ubuntu/Docker port of [`../kong.md`](../kong.md), which targets Rocky Linux with rootful
Podman. This version was deployed and verified on **192.168.1.91** (`ubuntu-1`, Ubuntu
24.04.5 LTS, Docker 29.1.3 from the Ubuntu `docker.io` package) on 2026-10-30.

The end result is the same gateway: Kong 3.6.1 in **database mode** (PostgreSQL), with 9
services, 9 routes and 9 rate-limiting plugins created from scratch through the Admin API
and stored in Postgres.

## What changed from the RHEL/Podman guide

| Topic | RHEL / Podman (`kong.md`) | Ubuntu / Docker (this guide) |
|---|---|---|
| Container engine | `sudo podman ...` | `docker ...` (user in the `docker` group, no `sudo`) |
| Install the engine | ships with the OS | `apt install docker.io docker-compose-v2` (Step 1) |
| SELinux | `setenforce 0`, permissive | not present. Ubuntu uses AppArmor, and Docker's default profile works with the read-only plugin mount, so nothing to change |
| Host firewall | `systemctl disable --now firewalld` | `ufw` is **inactive** by default. If you turned it on, allow 80 and 8001 (Step 1) |
| Container DNS | default `podman` network has `dns_enabled: false` | Docker's default `bridge` network has **no name resolution** between containers. A user-defined network does, so `kongnet` is still required |
| Verify DNS | `podman network inspect kongnet \| grep dns_enabled` | `docker exec kong getent hosts kong-db` (Step 7) |
| Start on boot | needs `podman-restart.service` for `--restart` to apply after a reboot | `dockerd` is enabled by default and restarts `unless-stopped` containers by itself |
| Image names | `docker.io/library/kong:3.6` | `kong:3.6` (Docker Hub is the default registry) |
| Read env / password | `podman inspect --format '{{.Config.Env}}' \| tr ',' '\n'` | `docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}'` |
| DB password | `PW=$(openssl rand ...)` in your shell only | also saved to `~/.kong-db-password` (mode 600) so later steps and other shells can reuse it |
| Config creation | 27 hand-typed `curl` calls | the same calls, or `./configure-kong.sh`, which does all 27 and stops on the first error |

## Overview — what you're building

| Component | Value |
|---|---|
| Host | `192.168.1.91` — Ubuntu 24.04 LTS |
| Kong image | `kong:3.6` (3.6.1, Community Edition) |
| Postgres image | `postgres:16` |
| Kong container | `kong` — ports `80:8000` (proxy), `8001:8001` (admin), restart `unless-stopped` |
| DB container | `kong-db` — user `kong`, DB `kong`, data volume `kong-db-data` |
| Network | `kongnet` (bridge, 10.90.0.0/24, gw 10.90.0.1). `kong-db` gets 10.90.0.2 |
| Plugins | `bundled` (default) |
| Config source | **Postgres is the source of truth**, created via the Admin API |
| Apps | 9 services + 9 routes + 9 rate-limiting plugins (listed below) |

The 9 apps this config serves (each with its own service, route and rate limit):

| Service | Upstream (host:port) | Route | Route host |
|---|---|---|---|
| `crapi-app` | `192.168.1.101:8888` | `crapi-root` | `crapi.cropseyit.com` |
| `crapi-mail` | `192.168.1.101:8025` | `crapi-mailhog` | `mail.cropseyit.com` |
| `dvga` | `192.168.1.101:5013` | `dvga-root` | `dvga.cropseyit.com` |
| `jenkins` | `192.168.1.100:8080` | `jenkins-root` | `jenkins.cropseyit.com` |
| `juice-nomon` | `192.168.1.99:30300` | `juice-nomon-root` | `juice-nomon.cropseyit.com` |
| `juice-shop` | `192.168.1.101:3000` | `juice-root` | `juice.cropseyit.com` |
| `k8s` | `192.168.1.75:80` | `k8s-root` | `k8s.cropseyit.com` |
| `notes` | `192.168.1.98:8000` | `notes-root` | `notes.cropseyit.com` |
| `vampi` | `192.168.1.99:30500` | `vampi-root` | `vampi.cropseyit.com` |

All routes use `paths: ["/"]`, `strip_path: false`, `preserve_host: true`.
All services use `connect_timeout: 60000` and the same rate limit:
`minute: 1000, hour: 20000, policy: local, limit_by: ip, fault_tolerant: true, hide_client_headers: false`.

---

## Step 1 — Host prep (Docker + firewall)

Skip the install if `docker version` already works without `sudo`.

```bash
# on 192.168.1.91
sudo apt update
sudo apt install -y docker.io docker-compose-v2 curl python3 openssl
sudo systemctl enable --now docker containerd
sudo usermod -aG docker "$USER"      # then log out and back in (or: newgrp docker)

docker version --format '{{.Server.Version}}'   # works without sudo
systemctl is-enabled docker                     # enabled, so containers come back after a reboot
```

Firewall: Ubuntu ships `ufw` turned off. Check it:

```bash
sudo ufw status                      # "Status: inactive", nothing to do
# only if it says active:
sudo ufw allow 80/tcp
sudo ufw allow 8001/tcp              # Admin API. Leave this out if only localhost should reach it
```

> Docker writes its own iptables rules for published ports, and those rules **bypass ufw**.
> Even with ufw active and no rule for 8001, `-p 8001:8001` is reachable from the LAN. To
> really restrict the Admin API, bind it to localhost (see the security note under
> *Admin API*). Don't count on ufw for that.

There's no SELinux on Ubuntu, so the RHEL `setenforce` step has no equivalent.

## Step 2 — Create the Docker network (with DNS)

Containers on Docker's default `bridge` network can't look each other up by name. Kong
needs to reach Postgres as `kong-db`, so create a user-defined network, which has Docker's
built-in DNS:

```bash
docker network create kongnet --subnet 10.90.0.0/24 --gateway 10.90.0.1
docker network inspect kongnet --format '{{.Driver}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'
# expect: bridge 10.90.0.0/24
```

(Name resolution is checked in Step 7, once both containers exist.)

## Step 3 — Pull images

```bash
docker pull kong:3.6
docker pull postgres:16
```

## Step 4 — Create the Postgres container

```bash
umask 077
openssl rand -hex 24 > ~/.kong-db-password      # mode 600, keep it
PW=$(cat ~/.kong-db-password)

docker run -d --name kong-db --network kongnet --restart unless-stopped \
  -e POSTGRES_DB=kong \
  -e POSTGRES_USER=kong \
  -e POSTGRES_PASSWORD="$PW" \
  -v kong-db-data:/var/lib/postgresql/data \
  postgres:16

# wait until Postgres accepts connections (instead of watching the logs)
until docker exec kong-db pg_isready -U kong -d kong >/dev/null 2>&1; do sleep 2; done
docker exec kong-db pg_isready -U kong -d kong   # "/var/run/postgresql:5432 - accepting connections"
```

> If you lose `~/.kong-db-password`, get the password back from the container:
> `docker inspect kong-db --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2-`
> (or from `KONG_PG_PASSWORD` on the `kong` container once it exists).

## Step 5 — Bootstrap the database (migrations)

```bash
docker run --rm --name kong-bootstrap --network kongnet \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  kong:3.6 kong migrations bootstrap
# expect: "64 migrations processed / 64 executed / Database is up-to-date"
```

## Step 6 — Start the Kong container (empty)

```bash
docker run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  kong:3.6
```

Binding host port 80 works without extra setup because `dockerd` runs as root. Rootless
Podman would need `net.ipv4.ip_unprivileged_port_start`, but that doesn't apply here.

## Step 7 — Verify the empty, healthy baseline

```bash
docker ps --format '{{.Names}}  {{.Status}}'        # kong  Up ... (healthy), kong-db  Up ...
docker exec kong getent hosts kong-db               # 10.90.0.2  kong-db   (container DNS works)
curl -s http://localhost:8001/status | python3 -m json.tool | head   # "reachable": true
curl -s http://localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'   # 3.6.1
curl -s http://localhost:8001/services | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "services")'   # 0
curl -s -o /dev/null -w 'proxy 404 check: %{http_code}\n' -H 'Host: nope.example.com' http://localhost:80/  # 404
docker logs kong 2>&1 | grep -iE '\[(error|crit)\]'   # expect nothing
```

The `kong` container shows `(health: starting)` for its first few seconds, then `(healthy)`.
The `kong:3.6` image has its own `kong health` healthcheck.

---

## Step 8 — Create the config (services, routes, rate limits)

Everything goes through the Admin API on port **8001**. Each app takes three calls:
**service → route → rate-limiting plugin**, in that order.

### Option A — the script (what was used on .91)

[`configure-kong.sh`](configure-kong.sh) makes all 27 calls from one table of apps. It
stops on the first call that doesn't return `201 Created`, so a typo can't leave you with
half the config and no warning.

```bash
# copy it to the Kong host, then on the host:
chmod +x configure-kong.sh
./configure-kong.sh                    # or: ADMIN=http://192.168.1.91:8001 ./configure-kong.sh from elsewhere
# ok  crapi-app  ->  192.168.1.101:8888  (crapi.cropseyit.com)
# ... one line per app, 9 total
```

Running it a second time fails on the first service with `409` (name already exists),
which is expected. To start over, see *Starting from scratch*.

### Option B — by hand

Identical to the RHEL guide. These are plain `curl` calls with nothing engine-specific in
them, so see **Step 8.1 – 8.9 in [`../kong.md`](../kong.md#step-8--create-the-config-services-routes-rate-limits)**.
Set `ADMIN=http://localhost:8001` first. The first app as an example:

```bash
ADMIN=http://localhost:8001

curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"crapi-app","host":"192.168.1.101","port":8888,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/crapi-app/routes -H 'Content-Type: application/json' \
  -d '{"name":"crapi-root","hosts":["crapi.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/crapi-app/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

## Step 9 — Verify everything

> **Wait about 5 seconds after Step 8 before testing the proxy.** In DB mode, Kong
> rebuilds its router in the background (`worker_state_update_frequency`, default 5 s).
> Proxy tests run right after the script all return **404** until that rebuild happens.
> That's what happened on .91. It isn't a broken config.

```bash
ADMIN=http://localhost:8001
sleep 5

curl -s $ADMIN/services | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "services")'   # 9
curl -s $ADMIN/routes   | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "routes")'     # 9
curl -s $ADMIN/plugins  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "plugins")'    # 9 (all rate-limiting)

# every route, through the proxy, using the Host header
for h in notes crapi juice dvga jenkins juice-nomon vampi mail k8s; do
  printf '%-12s ' $h; curl -s -o /dev/null -m 15 -w '%{http_code}\n' -H "Host: $h.cropseyit.com" http://localhost:80/
done
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: nope.example.com' http://localhost:80/  # 404

# rate limiting is applied
curl -sI -H 'Host: crapi.cropseyit.com' http://localhost:80/ | grep -i 'x-ratelimit'
```

Results on .91 (2026-10-30): all 200 except **jenkins → 403**. That 403 is Jenkins itself
refusing anonymous access (`Server: Jetty`, `X-Jenkins: 2.568.3` headers, and the
`X-RateLimit-*` headers show Kong proxied it). It isn't a Kong problem.

Check that the config survives a restart, and that it works from another LAN host:

```bash
docker restart kong && sleep 10
curl -s localhost:8001/services | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))'   # 9

# from any other host:
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: notes.cropseyit.com' http://192.168.1.91/   # 200
```

---

# Admin API ("the admin page")

Kong Community Edition has **no built-in web GUI** (Kong Manager is Enterprise-only). The
admin interface is the **REST Admin API** on port **8001**:

```
http://192.168.1.91:8001/
```

- `GET  /`          → version, edition, config
- `GET  /status`    → health, DB reachability
- `GET  /services`, `/routes`, `/plugins`, `/consumers` → list entities
- All entities support `POST` (create), `PATCH` (update), `DELETE`

> **Security note:** the Admin API is published on `0.0.0.0:8001`, so anyone on the network
> can reconfigure Kong. As noted in Step 1, **ufw won't block it**, because Docker's
> port-publish rules run ahead of ufw. To lock it down, recreate the container (Step 6) with
> `-p 127.0.0.1:8001:8001` (or a specific host IP) in place of `-p 8001:8001`.

**If you want a GUI:** the usual community option is **Konga** (https://konghub.io), which
needs its own Postgres for session storage. Nothing above depends on it.

```bash
ADMIN=http://192.168.1.91:8001
curl -s $ADMIN/services | python3 -m json.tool
curl -s $ADMIN/plugins  | python3 -m json.tool
```

---

# Modifying config

The Admin API calls for services, routes and plugins (create / `PATCH` / `DELETE`) are the
same on any host. See *Modifying config* in [`../kong.md`](../kong.md#modifying-config).
Changes are saved in Postgres and picked up live. Most of them need **no restart**, but
allow the ~5 s router rebuild described in Step 9.

## Upgrading / migrations

```bash
# pull the new tag, then run migrations before starting it:
docker pull kong:<new-tag>
docker run --rm --network kongnet \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$(cat ~/.kong-db-password)" \
  -e KONG_PG_DATABASE=kong \
  kong:<new-tag> kong migrations up
# then recreate the kong container (Step 6) with the new tag, and if the release notes
# say to, run `kong migrations finish` the same way
```

---

# Ops quick reference

```bash
# status / logs / restart
docker ps --filter name=kong
docker logs -f kong
docker restart kong
docker restart kong-db             # only if Postgres misbehaves

# current env (incl. DB password) of the kong container
docker inspect kong --format '{{range .Config.Env}}{{println .}}{{end}}'

# peek at the DB directly
docker exec kong-db psql -U kong -d kong -c 'select name, host, port from services order by name'

# data locations
#   Postgres data:  docker volume 'kong-db-data'
docker volume inspect kong-db-data --format '{{.Mountpoint}}'   # /var/lib/docker/volumes/kong-db-data/_data
```

## Starting from scratch (full teardown)

```bash
docker rm -f kong kong-db
docker volume rm kong-db-data          # deletes ALL Kong config
docker network rm kongnet
rm -f ~/.kong-db-password
# then repeat Steps 2–9
```
