# Kong Install Guide — 192.168.1.104 (DB Mode, from scratch)

Step-by-step guide for a clean Kong 3.6 install on **192.168.1.104** (Rocky Linux 10.2,
rootful Podman) using **database mode** (PostgreSQL). Nothing is copied from any other host —
the full config (9 services, 9 routes, 9 rate-limiting plugins) is created from scratch via
the Admin API and persisted in Postgres.

> **Used again on 192.168.1.103 (2026-10-30).** See
> [`rhel-podman/kong-rhel-103-deployment.md`](rhel-podman/kong-rhel-103-deployment.md) for
> what differed: Step 1 was skipped (SELinux kept enforcing, firewalld kept running, and
> both work), and `podman-restart.service` was enabled so containers come back after a
> reboot. After Step 8, config is managed as YAML with decK
> ([`rhel-podman/deck-yaml-config-rhel.md`](rhel-podman/deck-yaml-config-rhel.md)). Use
> that instead of the curl calls in *Modifying config*.

## Overview — what you're building

| Component | Value |
|---|---|
| Kong image | `docker.io/library/kong:3.6` (3.6.1, Community Edition) |
| Postgres image | `docker.io/library/postgres:16` |
| Kong container | `kong` — ports `80:8000` (proxy), `8001:8001` (admin), restart `unless-stopped` |
| DB container | `kong-db` — user `kong`, DB `kong`, data volume `kong-db-data` |
| Network | `kongnet` (10.90.0.0/24, gw 10.90.0.1) — `kong-db` is 10.90.0.2 |
| Plugins | `bundled` (default) |
| Config source | **Postgres is the source of truth**; created via the Admin API in this doc |
| Apps | 9 services + 9 routes + 9 rate-limiting plugins (listed below) |
| Host prep | firewalld disabled, SELinux permissive |

The 9 apps this config serves (each with its own service, route, and rate-limit):

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
All services use `connect_timeout: 60000` and the same rate-limit:
`minute: 1000, hour: 20000, policy: local, limit_by: ip, fault_tolerant: true, hide_client_headers: false`.

---

## Step 1 — Host prep

```bash
# on 192.168.1.104
sudo systemctl disable --now firewalld          # trusted LAN; Kong binds 0.0.0.0
sudo setenforce 0
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
sestatus                                          # expect: permissive mode
```

## Step 2 — Create the Podman network (with DNS)

The default `podman` network on this host has **DNS disabled**
(`podman network inspect podman` shows `"dns_enabled": false`), so containers cannot resolve
each other by name. Create a network with DNS:

```bash
sudo podman network create kongnet --subnet 10.90.0.0/24 --gateway 10.90.0.1
sudo podman network inspect kongnet | grep dns_enabled   # expect true
```

## Step 3 — Pull images

```bash
sudo podman pull docker.io/library/kong:3.6
sudo podman pull docker.io/library/postgres:16
```

## Step 4 — Create the Postgres container

```bash
PW=$(openssl rand -hex 24)   # keep this somewhere safe!

sudo podman run -d --name kong-db --network kongnet --restart unless-stopped \
  -e POSTGRES_DB=kong \
  -e POSTGRES_USER=kong \
  -e POSTGRES_PASSWORD="$PW" \
  -v kong-db-data:/var/lib/postgresql/data \
  docker.io/library/postgres:16

sudo podman logs kong-db   # wait for "database system is ready to accept connections"
```

> Recover the password any time with:
> `sudo podman inspect kong-db --format '{{json .Config.Env}}' | tr ',' '\n' | grep POSTGRES_PASSWORD`
> (the `json` form matters: plain `{{.Config.Env}}` is space-separated, so `tr ','` doesn't split it.)
> (or from the `KONG_PG_PASSWORD` env on the `kong` container once it exists.)

## Step 5 — Bootstrap the database (migrations)

```bash
sudo podman run --rm --name kong-bootstrap --network kongnet \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  docker.io/library/kong:3.6 kong migrations bootstrap
# expect: "64 migrations processed ... Database is up-to-date"
```

## Step 6 — Start the Kong container (empty)

```bash
sudo podman run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  docker.io/library/kong:3.6
```

## Step 7 — Verify the empty, healthy baseline

```bash
curl -s http://localhost:8001/status | python3 -m json.tool | head   # database: reachable: true
curl -s http://localhost:8001/services | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "services")'   # 0
curl -s -o /dev/null -w 'proxy 404 check: %{http_code}\n' -H 'Host: nope.example.com' http://localhost:80/  # 404
sudo podman logs kong 2>&1 | grep -iE 'error|crit'   # only the harmless nginx "user directive" warning
```

---

## Step 8 — Create the config (services, routes, rate-limits)

Everything is created through the Admin API on port **8001**. Each app is three calls:
**service → route → rate-limiting plugin**. Run them in that order.

> Set the admin base once:
> `ADMIN=http://localhost:8001`

### 8.1 — `crapi-app` (crapi.cropseyit.com → 192.168.1.101:8888)

```bash
# service
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"crapi-app","host":"192.168.1.101","port":8888,"protocol":"http","connect_timeout":60000}'

# route
curl -s -X POST $ADMIN/services/crapi-app/routes -H 'Content-Type: application/json' \
  -d '{"name":"crapi-root","hosts":["crapi.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

# rate-limiting
curl -s -X POST $ADMIN/services/crapi-app/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.2 — `crapi-mail` (mail.cropseyit.com → 192.168.1.101:8025)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"crapi-mail","host":"192.168.1.101","port":8025,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/crapi-mail/routes -H 'Content-Type: application/json' \
  -d '{"name":"crapi-mailhog","hosts":["mail.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/crapi-mail/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.3 — `dvga` (dvga.cropseyit.com → 192.168.1.101:5013)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"dvga","host":"192.168.1.101","port":5013,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/dvga/routes -H 'Content-Type: application/json' \
  -d '{"name":"dvga-root","hosts":["dvga.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/dvga/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.4 — `jenkins` (jenkins.cropseyit.com → 192.168.1.100:8080)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"jenkins","host":"192.168.1.100","port":8080,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/jenkins/routes -H 'Content-Type: application/json' \
  -d '{"name":"jenkins-root","hosts":["jenkins.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/jenkins/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.5 — `juice-nomon` (juice-nomon.cropseyit.com → 192.168.1.99:30300)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"juice-nomon","host":"192.168.1.99","port":30300,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/juice-nomon/routes -H 'Content-Type: application/json' \
  -d '{"name":"juice-nomon-root","hosts":["juice-nomon.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/juice-nomon/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.6 — `juice-shop` (juice.cropseyit.com → 192.168.1.101:3000)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"juice-shop","host":"192.168.1.101","port":3000,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/juice-shop/routes -H 'Content-Type: application/json' \
  -d '{"name":"juice-root","hosts":["juice.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/juice-shop/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.7 — `k8s` (k8s.cropseyit.com → 192.168.1.75:80)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"k8s","host":"192.168.1.75","port":80,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/k8s/routes -H 'Content-Type: application/json' \
  -d '{"name":"k8s-root","hosts":["k8s.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/k8s/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.8 — `notes` (notes.cropseyit.com → 192.168.1.98:8000)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"notes","host":"192.168.1.98","port":8000,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/notes/routes -H 'Content-Type: application/json' \
  -d '{"name":"notes-root","hosts":["notes.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/notes/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

### 8.9 — `vampi` (vampi.cropseyit.com → 192.168.1.99:30500)

```bash
curl -s -X POST $ADMIN/services -H 'Content-Type: application/json' \
  -d '{"name":"vampi","host":"192.168.1.99","port":30500,"protocol":"http","connect_timeout":60000}'

curl -s -X POST $ADMIN/services/vampi/routes -H 'Content-Type: application/json' \
  -d '{"name":"vampi-root","hosts":["vampi.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

curl -s -X POST $ADMIN/services/vampi/plugins -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'
```

## Step 9 — Verify everything

```bash
ADMIN=http://localhost:8001

curl -s $ADMIN/services | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "services")'   # 9
curl -s $ADMIN/routes   | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "routes")'     # 9
curl -s $ADMIN/plugins  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]), "plugins")'    # 9 (all rate-limiting)

# proxy tests (via Host header, same as production)
curl -sI -H 'Host: notes.cropseyit.com'    http://localhost:80/   # 200, X-RateLimit-* headers
curl -sI -H 'Host: crapi.cropseyit.com'   http://localhost:80/   # 200
curl -sI -H 'Host: juice.cropseyit.com'   http://localhost:80/   # 200
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: nope.example.com' http://localhost:80/  # 404

# confirm rate-limiting is actually applied
curl -sI -H 'Host: crapi.cropseyit.com' http://localhost:80/ | grep -i 'x-ratelimit'
```

---

# Admin API ("the admin page")

Kong Community Edition has **no built-in web GUI** (Kong Manager is Enterprise-only).
The admin interface is the **REST Admin API** on port **8001**:

```
http://192.168.1.104:8001/
```

- `GET  /`          → version, edition, config
- `GET  /status`    → health, DB reachability
- `GET  /services`, `/routes`, `/plugins`, `/consumers` → list entities
- All entities support `POST` (create), `PATCH` (update), `DELETE`

> Security note: the Admin API is bound to `0.0.0.0:8001`.
> Anyone on the network can reconfigure Kong — keep it that way only while trusted,
> or later change to `-e KONG_ADMIN_LISTEN=127.0.0.1:8001` / a specific IP.

**If you want a GUI:** the common community option is **Konga** (https://konghub.io),
which needs its own Postgres for session storage. Everything above works without it.

Useful one-liners:

```bash
ADMIN=http://192.168.1.104:8001

curl -s $ADMIN/services | python3 -m json.tool
curl -s $ADMIN/plugins  | python3 -m json.tool
```

Or use Postman/Insomnia against `http://192.168.1.104:8001`.

---

# Modifying config

All changes go through the Admin API and are persisted in Postgres (survive restarts).
The running Kong picks up changes automatically — **no restart needed** for most changes.

## Services

```bash
# list
curl -s http://localhost:8001/services | python3 -m json.tool

# create (host/port/protocol instead of url in DB mode)
curl -s -X POST http://localhost:8001/services \
  -H 'Content-Type: application/json' \
  -d '{"name":"myapp","host":"192.168.1.101","port":8080,"protocol":"http"}'

# update
curl -s -X PATCH http://localhost:8001/services/myapp \
  -H 'Content-Type: application/json' \
  -d '{"port":9090,"connect_timeout":5000}'

# delete (also deletes its routes/plugins)
curl -s -X DELETE http://localhost:8001/services/myapp
```

## Routes

```bash
# create a route for an existing service
curl -s -X POST http://localhost:8001/services/myapp/routes \
  -H 'Content-Type: application/json' \
  -d '{"name":"myapp-root","hosts":["myapp.cropseyit.com"],"paths":["/"],"strip_path":false,"preserve_host":true}'

# list / update / delete
curl -s http://localhost:8001/routes
curl -s -X PATCH http://localhost:8001/routes/myapp-root -d '{"paths":["/api"]}'
curl -s -X DELETE http://localhost:8001/routes/myapp-root
```

## Plugins

```bash
# add a service-level rate-limiting plugin (matches the existing pattern)
curl -s -X POST http://localhost:8001/services/myapp/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":1000,"hour":20000,"policy":"local","limit_by":"ip","fault_tolerant":true,"hide_client_headers":false}}'

# update it
curl -s -X PATCH http://localhost:8001/plugins/<id> \
  -H 'Content-Type: application/json' -d '{"config":{"minute":500}}'

# remove
curl -s -X DELETE http://localhost:8001/plugins/<id>

# global plugin (applies to all routes), e.g. a global rate limit
curl -s -X POST http://localhost:8001/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":100,"hour":10000,"policy":"local","limit_by":"ip"}}'
```

## Upgrading / migrations

```bash
# after swapping the image tag, before starting:
sudo podman run --rm --network kongnet \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$(sudo podman inspect kong --format '{{json .Config.Env}}' | python3 -c 'import json,sys; print([e.split("=",1)[1] for e in json.load(sys.stdin) if e.startswith("KONG_PG_PASSWORD=")][0])')" \
  -e KONG_PG_DATABASE=kong \
  docker.io/library/kong:<new-tag> kong migrations up
```

---

# Ops quick reference

```bash
# status / logs / restart
sudo podman ps | grep kong
sudo podman logs -f kong
sudo podman restart kong
sudo podman restart kong-db          # only if Postgres misbehaves

# current env (incl. DB password) of the kong container
sudo podman inspect kong --format '{{json .Config.Env}}'

# data locations
#   Postgres data:   podman volume 'kong-db-data'  (sudo podman volume inspect kong-db-data)
```

## Starting from scratch (full teardown)

```bash
sudo podman rm -f kong kong-db
sudo podman volume rm kong-db-data
sudo podman network rm kongnet
# then repeat Steps 1–9
```
