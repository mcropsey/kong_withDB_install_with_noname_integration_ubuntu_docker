# Kong config as YAML (decK) — `kong.yaml` is the source of truth

The gateway on **192.168.1.91** is managed through one YAML file,
[`deck/kong.yaml`](deck/kong.yaml), applied with **decK**, Kong's official
declarative-config CLI. It works with open-source Kong in DB mode. You edit the YAML, look
at the diff, and apply. decK makes Kong's Postgres match the file.

This replaces making changes with `curl` against the Admin API (Step 8 of
[`kong-ubuntu-docker.md`](kong-ubuntu-docker.md)). Kong itself is unchanged: it's still DB
mode, and Postgres still holds the running config. decK just keeps Postgres in step with
the file, and the file lives in git.

> ⚠️ **Apply is a full sync.** Anything in Kong that is **not** in `kong.yaml` (a service,
> route, plugin, consumer…) gets **deleted** on the next apply. That's the point: the file
> is the truth. It also means **don't make changes with curl any more**, because the next
> apply wipes them. Put every change in the YAML.

---

## What was installed and set up (2026-10-30)

| Item | Where / what |
|---|---|
| decK **v1.69.0** | `/usr/local/bin/deck` on .91 (GitHub release, sha256 checked against `checksums.txt`) |
| Config file | [`ubuntu-docker/deck/kong.yaml`](deck/kong.yaml): the 9 services / 9 routes / 9 rate limits |
| Wrapper | [`ubuntu-docker/deck/kong-config.sh`](deck/kong-config.sh): `validate`, `diff`, `apply`, `backup`, `restore` |
| Repo clone on .91 | `~/kong_withDB_install_with_noname_integration_ubuntu_docker` (git push works there) |
| Backups | `~/kong-backups/kong-YYYYMMDD-HHMMSS.yaml` on .91, one taken automatically before every apply |

How it was checked:

- `kong.yaml` was hand-written with only the non-default fields. `deck gateway diff`
  against the running gateway showed `Created: 0 Updated: 0 Deleted: 0`, so the file
  matches exactly what Step 8 built.
- Round trip: a test service + route + `response-transformer` plugin and a global
  `correlation-id` plugin were applied from a copy of the file and served traffic with
  the added headers. A stray service was then created by hand with curl. Applying the real
  `kong.yaml` deleted all 5 extras and brought the diff back to 0.
- Bad input is stopped before anything changes: `minute: lots` → `schema violation
  (config.minute: expected a number)`, and a misspelled plugin name → `No plugin named
  'rate-limitting'`.

### Install steps (to repeat on another host)

```bash
VER=1.69.0      # latest: https://github.com/Kong/deck/releases
d=$(mktemp -d) && cd "$d"
curl -sSLO https://github.com/Kong/deck/releases/download/v$VER/deck_${VER}_linux_amd64.tar.gz
curl -sSLO https://github.com/Kong/deck/releases/download/v$VER/checksums.txt
grep " deck_${VER}_linux_amd64.tar.gz$" checksums.txt | sha256sum -c -    # must say OK
tar xzf deck_${VER}_linux_amd64.tar.gz deck
sudo install -m 0755 deck /usr/local/bin/deck
cd / && rm -rf "$d"

deck version
deck gateway ping --kong-addr http://localhost:8001     # "Successfully connected to Kong! Kong version: 3.6.1"

git clone https://github.com/mcropsey/kong_withDB_install_with_noname_integration_ubuntu_docker.git
cd kong_withDB_install_with_noname_integration_ubuntu_docker/ubuntu-docker/deck
./kong-config.sh diff          # on .91: 0 / 0 / 0
```

On a **brand-new** gateway (after Step 7 of the base guide), `./kong-config.sh apply`
creates the whole config in one go. That replaces Step 8 and `configure-kong.sh`.

---

## Everyday workflow

```bash
ssh mcropsey@192.168.1.91
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker/ubuntu-docker/deck
git pull                                  # pick up changes made elsewhere

vi kong.yaml                              # 1. edit
./kong-config.sh validate                 # 2. check syntax + plugin schemas (silent = OK)
./kong-config.sh diff                     # 3. preview: what will be created/updated/deleted
./kong-config.sh apply                    # 4. backs up, shows the diff, asks y/N, syncs

sleep 5 && curl -sI -H 'Host: <new-host>.cropseyit.com' http://localhost/   # 5. test (see note)

git commit -am "kong: add <thing>" && git push                             # 6. record it
```

- **Wait ~5 s before testing.** Kong rebuilds its router in the background after each
  change. Testing right away gives a 404, even though the config is correct.
- `apply` prints the change list twice, once from the preview and once from the sync
  itself. That's expected.
- To apply from another machine that has decK installed, run
  `KONG_ADDR=http://192.168.1.91:8001 ./kong-config.sh diff`.
- Read the **`deleting …`** lines in the diff carefully. If you didn't mean to remove
  something, answer `N` and add it to the YAML.

---

## Layout of `kong.yaml`

```yaml
_format_version: "3.0"

services:                     # one entry per backend app
- name: notes                 # unique; this is how decK matches entities
  protocol: http
  host: 192.168.1.98
  port: 8000
  connect_timeout: 60000
  routes:                     # how requests reach this service
  - name: notes-root
    hosts: [notes.cropseyit.com]
    paths: [/]
    strip_path: false
    preserve_host: true
    # plugins: [...]          # plugins that apply to this route only
  plugins:                    # plugins that apply to the whole service
  - name: rate-limiting
    config: { minute: 1000, hour: 20000, policy: local, limit_by: ip,
              fault_tolerant: true, hide_client_headers: false }

plugins: []                   # GLOBAL plugins (apply to every request), top level
consumers: []                 # API clients, for auth plugins
upstreams: []                 # load-balanced pools of backends
```

Rules of thumb:

- **Names are identities.** Renaming `name:` means "delete the old one, create a new
  one", not a rename.
- Leave out anything that should stay at Kong's default (`read_timeout 60000`, `retries
  5`, `protocols [http, https]`, …). decK fills it in.
- Indentation matters (2 spaces). Lists start with `- `. `./kong-config.sh validate`
  catches most mistakes.

---

## Cookbook

### Add a new app (service + route + the standard rate limit)

Copy an existing block under `services:` and change the values:

```yaml
# --- grafana: grafana.cropseyit.com -> 192.168.1.98:3000
- name: grafana
  protocol: http
  host: 192.168.1.98
  port: 3000
  connect_timeout: 60000
  routes:
  - name: grafana-root
    hosts: [grafana.cropseyit.com]
    paths: [/]
    strip_path: false
    preserve_host: true
  plugins:
  - name: rate-limiting
    config:
      minute: 1000
      hour: 20000
      policy: local
      limit_by: ip
      fault_tolerant: true
      hide_client_headers: false
```

DNS (or the client's hosts file) must point `grafana.cropseyit.com` at 192.168.1.91,
because Kong routes on the `Host` header.

### Add another route to an existing service

Add a second entry under that service's `routes:`. Example: send `api.juice.cropseyit.com`
only for `/rest` and `/api`:

```yaml
  routes:
  - name: juice-root
    hosts: [juice.cropseyit.com]
    paths: [/]
    strip_path: false
    preserve_host: true
  - name: juice-api
    hosts: [api.juice.cropseyit.com]
    paths: [/rest, /api]
    strip_path: false
```

Path-based routing on the bare IP (no Host header) works by leaving out `hosts:`:
`paths: [/notes]` plus `strip_path: true` sends `http://192.168.1.91/notes/x` to the
upstream as `/x`.

### Change an upstream / port / timeout

Edit the field in place (`host:`, `port:`, `connect_timeout:`). The diff shows
`updating service …`.

### Change the rate limit for one app

Edit the numbers under that service's `rate-limiting` → `config`. Example:
`minute: 100`.

### Add a plugin

A plugin's scope comes from **where you put it**:

| Put it under… | Applies to |
|---|---|
| a service's `plugins:` | every route of that service |
| a route's `plugins:` | that route only |
| top-level `plugins:` | **every** request through Kong (global) |
| a consumer's `plugins:` | requests from that consumer |

Examples:

```yaml
# service-level: add a response header to vampi
- name: vampi
  ...
  plugins:
  - name: rate-limiting
    config: { ... }
  - name: response-transformer
    config:
      add:
        headers: ["X-Gateway:kong-91"]

# route-level: CORS on one route only
  routes:
  - name: dvga-root
    ...
    plugins:
    - name: cors
      config:
        origins: ["*"]
        methods: [GET, POST, OPTIONS]

# global (top level, same indent as services:)
plugins:
- name: correlation-id
  config:
    header_name: X-Request-ID
    echo_downstream: true
```

Finding a plugin's config fields:

- Docs: https://docs.konghq.com/hub/ (choose the plugin, then "Configuration reference")
- The running Kong knows its own schema:
  `curl -s localhost:8001/schemas/plugins/cors | python3 -m json.tool | less`
- List the plugins this Kong can run:
  `curl -s localhost:8001/ | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["plugins"]["available_on_server"]))'`

### Turn a plugin off without deleting it

Add `enabled: false` to it. Set `true` (or remove the line) to turn it back on.

### Remove something

Delete its block from the YAML and apply. Deleting a service block also removes its routes
and plugins (the diff lists each one).

### Consumers + API keys (auth)

```yaml
services:
- name: vampi
  ...
  plugins:
  - name: key-auth            # require an API key on vampi
    config:
      key_names: [apikey]

consumers:
- username: pentest-team
  keyauth_credentials:
  - key: ${{ env "DECK_PENTEST_KEY" }}
```

```bash
DECK_PENTEST_KEY='…' ./kong-config.sh apply
```

> **This repo is public. Never type a secret straight into `kong.yaml`.** Use decK's
> `${{ env "DECK_NAME" }}` substitution (the variable name **must** start with `DECK_`) and
> set the variable only when you run diff/apply. If it's missing, decK refuses to run.

### Load-balance across several backends

```yaml
upstreams:
- name: juice-pool
  targets:
  - target: 192.168.1.101:3000
    weight: 100
  - target: 192.168.1.102:3000
    weight: 100

services:
- name: juice-shop
  protocol: http
  host: juice-pool            # the upstream's name, not an IP
  port: 3000
  ...
```

### Start from what's live

To copy something that was set up by hand (or to see every field):

```bash
deck gateway dump --kong-addr http://localhost:8001 -o /tmp/live.yaml --yes
```

The dump lists every default value, so copy only the fields you care about into
`kong.yaml`.

---

## Custom plugins (e.g. Noname `nonamesecurity`)

A custom plugin has **two parts**, and only one of them goes in the YAML:

1. **The code**: the Lua files **built into a custom image** (vendor-recommended, see
   [`../noname-image/Dockerfile`](../noname-image/Dockerfile)), and the `kong` container
   run from that image with `KONG_PLUGINS=bundled,<name>`. Not YAML. See Steps 1–3 of
   [`noname-kong-install-ubuntu-docker.md`](noname-kong-install-ubuntu-docker.md)
   (RHEL: [`../rhel-podman/noname-kong-install-rhel.md`](../rhel-podman/noname-kong-install-rhel.md)).
2. **The instance**: the YAML entry. For Noname, instead of the `curl -X POST /plugins` in
   Step 4 of that guide, add it globally:

   ```yaml
   plugins:
   - name: nonamesecurity
   ```

   or under one service's `plugins:` to scope it.

This matches what worked in DB-less mode, and Noname's own DB-less example: the same
`KONG_PLUGINS` value and the same `- name: nonamesecurity` entry, with no `config:`.

Plugin **upgrades** only change the image tag (new build, recreate the container). The YAML
entry stays as it is.

**Order matters:** the code first (recreate the container from the plugin image), then add the YAML entry and
apply. If you add the entry first, `validate` fails with `No plugin named
'nonamesecurity'`, which stops the apply, so you can't break Kong this way. To roll back,
remove the YAML entry and apply **before** recreating the container on the stock `kong:3.6` image.

Once a custom plugin's instance is managed in YAML, don't add or remove it with curl. The
next apply would undo it.

---

## Backups, rollback and drift

```bash
./kong-config.sh backup                                  # manual snapshot
ls -lt ~/kong-backups | head                             # one per apply
./kong-config.sh restore ~/kong-backups/kong-20261030-213107.yaml   # put Kong back to that state
```

- **Undo the last change the git way:** `git revert HEAD && ./kong-config.sh apply`.
- **Restore from a backup:** `restore` syncs Kong to the backup file. After that, Kong no
  longer matches `kong.yaml`, so fix the YAML (or `git revert`) and apply again, or the
  next apply will redo the change you just undid.
- **Drift check:** someone used curl, or you're unsure? `./kong-config.sh diff`. Anything
  other than `0 / 0 / 0` means Kong and the file disagree. Apply to enforce the file, or
  copy the change into the YAML first if it should stay.
- Backups are full dumps with every default listed, and **can contain secrets**
  (consumer keys). They stay in `~/kong-backups` on .91 and are not in git.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `deck: command not found` | install decK (above) |
| `Error: … connection refused` | Kong is down (`docker ps`), or wrong `KONG_ADDR` |
| `schema violation (…)` | a bad value for that field. Check the plugin's schema (`/schemas/plugins/<name>`) |
| `No plugin named 'x'` | typo, or a custom plugin whose code isn't loaded (see *Custom plugins*) |
| `environment variable 'DECK_…' present in state file but not set` | set it on the command line: `DECK_X=… ./kong-config.sh apply` |
| diff wants to delete something you need | it was created outside the YAML. Answer `N`, add it to `kong.yaml`, apply again |
| new route returns 404 right after apply | wait ~5 s for the router rebuild |
| diff keeps showing an `updating` for a field you didn't touch | the YAML value differs from what Kong stores (e.g. list order). Set it exactly as `deck gateway dump` shows it |
