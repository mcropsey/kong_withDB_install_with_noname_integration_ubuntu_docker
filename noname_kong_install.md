# Noname API Security — Kong Plugin Install (192.168.1.104)

> **Superseded for .91 and .103 (2026-10-30).** Those gateways use Noname's
> custom-image install (the plugin built into a `kong-noname` image, not mounted from
> `/opt`), with the plugin turned on from decK `kong.yaml`, not with curl. See
> [`rhel-podman/noname-kong-install-rhel.md`](rhel-podman/noname-kong-install-rhel.md)
> (Rocky/Podman) and
> [`ubuntu-docker/noname-kong-install-ubuntu-docker.md`](ubuntu-docker/noname-kong-install-ubuntu-docker.md)
> (Ubuntu/Docker). This page is the record of the original folder-mount + curl install on
> .104. Its *How it works* and *Configuration reference* sections still apply everywhere.

Standalone guide for installing the **nonamesecurity** Kong plugin (v5.0.1) onto the
Kong 3.6.1 gateway running on **192.168.1.104** (Rocky Linux 10.2, rootful Podman,
**DB mode** — Postgres is the source of truth).

This doc is self-contained: it assumes only the base Kong gateway is already running
(the `kong` + `kong-db` containers on network `kongnet`). It does **not** depend on any
other doc. Every command is given in full.

---

## What you're installing

| Item | Value |
|---|---|
| Plugin | `nonamesecurity` **v5.0.1** (Noname API Security) |
| What it does | Sends API traffic to the Noname engine (async **inspection**) and, optionally, blocks requests by policy (inline **prevention**) |
| Kong target | `kong:3.6` container, DB mode, `kongnet` |
| Plugin code lands in | `/opt/kong/plugins/nonamesecurity/` on `.104`, mounted read-only into the container |
| Plugin source (Mac) | `~/Downloads/noname-security-kong-policy/kong/plugins/nonamesecurity/` (6 `.lua` files) |
| Instance created via | Admin API `POST /plugins` (lives in Postgres — survives restarts) |
| Kong execution priority | **2501** — runs **before** `rate-limiting` (910) in the `access` phase |

The plugin needs its Lua files on the data plane **and** uses background timers, so it can
only run on a Kong runtime you control — which this is (a container we own). It is **not**
compatible with fully Kong-hosted runtimes (Konnect Serverless / Dedicated Cloud), which
we are not using.

Noname has tested this plugin on Kong **2.6 – 3.15**; our **3.6.1** is in range.

---

## How it works (read this first)

- **Inspection is asynchronous.** Request/response records are batched and sent to the
  engine in the background — negligible added latency.
- **Prevention is inline.** Before a request is proxied, the plugin checks it against
  cached rules and may block it. It uses a short **fail-open** timeout
  (`NN_PREVENTION_CHECK_TIMEOUT_MS`, default **50 ms**), so a slow or down engine never
  stalls legitimate traffic.
- **Prevention is ON by default** (`NN_PREVENTION_ENABLED = true`). Blocked requests return
  **403** (`NN_PREVENTION_STATUS_CODE`). If you want inspection-only, set
  `NN_PREVENTION_ENABLED = false` in `schema.lua` **before first start**.
- **Priority 2501** means it runs **before** `rate-limiting` (910):
  - a prevention block is a Noname **403**, never a Kong **429**, and it doesn't consume
    rate-limit quota;
  - inspection still captures requests that `rate-limiting` would later 429.
- **Payloads are capped** at **1 MB** each (`NN_MAX_PAYLOAD_SIZE = 1024` KB) — larger
  request/response bodies are not fully inspected.
- **Fail-open everywhere.** The handler is `pcall`-wrapped; an error fails open and logs
  `[NONAME] Critical error … failing open`.

---

## Prerequisites (verify once)

```bash
ssh mcropsey@192.168.1.104
sudo podman ps --format '{{.Names}}  {{.Status}}'        # expect: kong  Up, kong-db  Up
sudo podman inspect kong --format '{{json .Config.Env}}' | tr ',' '\n' | grep KONG_DATABASE   # KONG_DATABASE=postgres
curl -s http://localhost:8001/status | python3 -c 'import json,sys; print("db:", json.load(sys.stdin)["database"]["reachable"])'   # True
sudo ls /opt/kong/plugins 2>/dev/null                      # expect: nothing yet (no plugins/ dir)
```

The plugin files on the Mac:

```
~/Downloads/noname-security-kong-policy/kong/plugins/nonamesecurity/
├── batch_queue.lua   ├── handler.lua     ├── schema.lua
├── configuration.lua ├── prevention.lua  └── utils.lua
```

`schema.lua` arrives **pre-filled** with your engine URL, source index, and source key
for this integration profile — that's why there's no separate credential step. Check them:

```bash
grep -E "NN_ENGINE_URL|NN_SOURCE_INDEX|NN_SOURCE_KEY|NN_PREVENTION_ENABLED" \
  ~/Downloads/noname-security-kong-policy/kong/plugins/nonamesecurity/schema.lua
```

Both the engine URL and source key should be real values, not placeholders.

---

## Step 1 — Copy the plugin files onto .104

```bash
# from the Mac
tar czf - -C ~/Downloads/noname-security-kong-policy kong/plugins/nonamesecurity | \
  ssh mcropsey@192.168.1.104 "sudo sh -c 'mkdir -p /opt/kong/plugins && tar xzf - -C /opt'"

# make the tree readable by the (uid 1000) kong user in the container
ssh mcropsey@192.168.1.104 "sudo chown -R 1000:1000 /opt/kong/plugins"

# verify on .104
ssh mcropsey@192.168.1.104 "ls /opt/kong/plugins/nonamesecurity
sudo grep -E 'NN_ENGINE_URL|NN_SOURCE_INDEX|NN_SOURCE_KEY' /opt/kong/plugins/nonamesecurity/schema.lua"
```

> We only ship the 6 `nonamesecurity/*.lua` files — the `spec/`, `.busted`, `.rock`, and
> `fake-lambda-custom-plugin` items in the download are test/dev artifacts and are not needed.

---

## Step 2 — Recreate the Kong container with the plugin mounted + enabled

This is the **one and only** time a container recreation is required. It's unavoidable
because two things are fixed at container-creation time and cannot be added to a running
container:

1. the **mount** that puts the Lua files into the container's Lua path, and
2. the **`KONG_PLUGINS`** env var that tells Kong to load the plugin.

Kong loads plugin **code** into memory only at process start — DB mode gives you hot-reload
of **configuration** (instances, services, routes), not of plugin code. After this step,
day-to-day changes never need a recreate (see *Ops*).

```bash
# on .104 — recover the DB password from the running container
PW=$(sudo podman inspect kong --format '{{.Config.Env}}' | tr ',' '\n' \
      | grep KONG_PG_PASSWORD | tr -d ' "' | cut -d= -f2)

sudo podman rm -f kong

sudo podman run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  -e KONG_PLUGINS=bundled,nonamesecurity \
  -v /opt/kong/plugins/nonamesecurity:/usr/local/share/lua/5.1/kong/plugins/nonamesecurity:ro \
  docker.io/library/kong:3.6
```

Two things to get right:

- **Mount the specific plugin folder**, not `/opt/kong/plugins`. Mounting the parent over
  `/usr/local/share/lua/5.1/kong/plugins/` would shadow Kong's bundled plugins and break
  `rate-limiting`.
- **Keep `bundled` in `KONG_PLUGINS`** for the same reason — `bundled,nonamesecurity` gives
  you the stock plugins *plus* Noname.

---

## Step 3 — Confirm the plugin code is loaded in the cluster

```bash
curl -s http://localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["plugins"]["enabled_in_cluster"])'
# expect: ['nonamesecurity', 'rate-limiting']  (order may vary)
```

If `nonamesecurity` is missing, the mount path or `KONG_PLUGINS` is wrong — check Step 2.

---

## Step 4 — Register the plugin instance (Admin API)

In DB mode the plugin **instance** lives in Postgres, created via the Admin API. There is no
config in the body — all tuning is in `schema.lua` (engine URL, source index/key) and in the
API Security UI.

**Global** — covers every service/route:

```bash
curl -s -X POST http://localhost:8001/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"nonamesecurity"}'
```

**Or scoped to one service** (e.g. only crapi):

```bash
curl -s -X POST http://localhost:8001/services/crapi-app/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"nonamesecurity"}'
```

> **Order matters in DB mode.** If a `nonamesecurity` instance exists in Postgres but the
> container can't load the code (missing mount / `KONG_PLUGINS`), Kong **fails to start**
> with `plugin 'nonamesecurity' not found`. That's why Step 2 (code) comes before Step 4
> (DB record). Rollback is the reverse: delete the DB record *first*, then change the container.

---

## Step 5 — Verify end-to-end

```bash
# instance exists
curl -s http://localhost:8001/plugins | python3 -m json.tool | grep -A2 nonamesecurity

# gateway still healthy, rate-limit headers intact
curl -sI -H 'Host: crapi.cropseyit.com' http://localhost:80/     # 200, X-RateLimit-* present

# nothing new in the logs
sudo podman logs kong 2>&1 | grep -iE 'error|crit'               # expect nothing new
```

Then send **real traffic** through a proxied app and confirm it lands in the
API Security UI (Settings > Integrations). If prevention is on, a blocked request will
return **403** with (optionally) the `x-blocked-by-noname` header.

---

## Configuration reference (schema.lua, v5.0.1)

Much of the ongoing behavior is **UI-managed and fetched periodically** (no redeploy).
The rest is **fixed in `schema.lua`** — change those by editing the file + restarting Kong.

| Area | Field (default) | Notes |
|---|---|---|
| Identity | `NN_ENGINE_URL` | pre-filled per integration profile; includes `?structure=base64-payload` |
| | `NN_SOURCE_INDEX` (2), `NN_SOURCE_KEY` | pre-filled; new per integration profile |
| | `NN_SOURCE_TYPE` (7), `NN_VERSION` (5.0.1) | |
| Prevention | `NN_PREVENTION_ENABLED` (**true**) | on by default — set `false` for inspection-only |
| | `NN_PREVENTION_STATUS_CODE` (403) | response on block |
| | `NN_PREVENTION_HEADER_NAME` (`x-blocked-by-noname`) | sent only if `NN_PREVENTION_SEND_HEADER` is `true` (default `false`) |
| | `NN_PREVENTION_CHECK_TIMEOUT_MS` (50) | fail-open window for the inline check |
| | `NN_PREVENTION_RULES_CLEAR_THRESHOLD` (10) | |
| Timeouts | `NN_CONNECTION_TIMEOUT` (500 ms), `NN_SEND_TIMEOUT` (1000 ms), `NN_READ_TIMEOUT` (500 ms) | mostly UI-managed |
| | `NN_ADAPTER_FETCH_INTERVAL` (60 s), `NN_ADAPTER_FETCH_TIMEOUT` (30 s) | config/rules refresh cadence |
| Throughput | `NN_MAX_PAYLOAD_SIZE` (1024 KB = 1 MB) | per request and per response |
| | `NN_MAX_BATCH_QUEUE_SIZE` (100), `NN_MAX_CONCURRENT_PROCESSES` (100) | |
| | `NN_RETRY_COUNT` (1), `NN_FLUSH_TIMEOUT` (1 s), `NN_KEEPALIVE` (60000 ms) | |
| Behavior | `NN_SUPPORT_CHUNKED_REQUEST` (false) | |
| | `NN_SSL_VERIFY` (true), `NN_ENRICH_HTTPS_CONNECTION_WITH_SNI` (true) | |
| | `NN_DEBUG_ENABLED` (**false**) | see *Debug logging* |
| Proxy | `NN_PROXY_URL` (None), `NN_PROXY_USERNAME`/`NN_PROXY_PASSWORD` | egress proxy, if any |

UI-managed (fetched live, no redeploy): connection/send/read timeout, max body size, batch
size, chunked-traffic support, prevention on/off + header + status code + rules-clear
retries, and the config-fetch interval/timeout.

---

## Ops

| Change | How | Restart needed? |
|---|---|---|
| Add/remove the plugin **instance** | Admin API `POST`/`DELETE /plugins` | **No** (DB mode, hot) |
| Change services / routes | Admin API | **No** |
| Tune `schema.lua` (e.g. flip prevention) | edit `/opt/kong/plugins/nonamesecurity/schema.lua` | **Yes** — `sudo podman restart kong` (live mount picks it up) |
| Update the plugin to a new version | replace the folder, then restart | **Yes** |
| Change `KONG_PLUGINS` or the mount | recreate the container (Step 2) | **Yes** |

Update to a new plugin version (a new integration profile generates a new
`NN_SOURCE_INDEX`/`NN_SOURCE_KEY` — replace the **whole** folder, never merge files):

```bash
# Mac: download the new zip, re-run the Step 1 tar pipe to .104
# .104:
sudo rm -rf /opt/kong/plugins/nonamesecurity
sudo cp -r <new>/kong/plugins/nonamesecurity /opt/kong/plugins/
sudo podman restart kong
```

---

## Debug logging

To see `[NONAME]` log lines you need **both**:

```bash
# 1. enable in schema.lua
sudo sed -i 's/NN_DEBUG_ENABLED = { type = "boolean", default = false }/NN_DEBUG_ENABLED = { type = "boolean", default = true }/' \
  /opt/kong/plugins/nonamesecurity/schema.lua

# 2. the container must log at info (Kong's default "notice" hides debug)
#    add -e KONG_LOG_LEVEL=info to the container (Step 2), then:
sudo podman restart kong
sudo podman logs -f kong | grep NONAME
```

---

## Rollback

```bash
# 1. delete the instance (id from the list)
curl -s http://localhost:8001/plugins | python3 -c \
  'import json,sys; [print(p["id"]) for p in json.load(sys.stdin)["data"] if p["name"]=="nonamesecurity"]'
curl -s -X DELETE http://localhost:8001/plugins/<id>

# 2. recreate the container WITHOUT the plugin (back to the plain base gateway)
sudo podman rm -f kong
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

# 3. if fully uninstalling
sudo rm -rf /opt/kong/plugins/nonamesecurity
```

Finally, delete the integration profile in the API Security UI. Previously collected data
is **not** removed by uninstalling.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container exits immediately | `sudo podman logs kong` — usually `plugin 'nonamesecurity' not found` (DB record exists but mount/`KONG_PLUGINS` wrong) or missing files |
| `plugin 'nonamesecurity' not found` | `sudo podman exec kong ls /usr/local/share/lua/5.1/kong/plugins/nonamesecurity` — if empty, the mount path is wrong |
| Kong starts but `rate-limiting` is gone | `bundled` dropped from `KONG_PLUGINS`, or you mounted the whole `/opt/kong/plugins` folder |
| Loads fine, nothing in the UI | Instance missing (`POST /plugins` never ran), or `.104` can't reach the engine: `curl -sS -o /dev/null -w '%{http_code}\n' "https://michaelc-lab.nonamesec.com/engine?structure=base64-payload"` (must match `NN_ENGINE_URL`) |
| No `[NONAME]` log lines | Needs **both** `NN_DEBUG_ENABLED = true` in `schema.lua` **and** `-e KONG_LOG_LEVEL=info` in the container |
| Prevention not blocking | `NN_PREVENTION_ENABLED` is `false`, or no matching rules in the UI; confirm with `[NONAME] Blocking request …` when debug is on |

---

## Scope

Specific to: plugin Lua on disk, mounted read-only into a single rootful Podman `kong`
container on `kongnet`; Postgres-backed Kong (DB mode); admin + proxy in the same container
(so the "install on both admin and proxy" split-deployment note does not apply here). A
DB-less or split admin/proxy deployment would need the plugin on the proxy runtime and a
declarative `plugins:` entry instead of the Admin API call.
