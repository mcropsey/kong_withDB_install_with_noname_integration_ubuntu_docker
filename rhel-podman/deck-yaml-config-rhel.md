# Kong config as YAML (decK) on RHEL/Rocky + Podman — 192.168.1.103

The RHEL version of [`../ubuntu-docker/deck-yaml-config.md`](../ubuntu-docker/deck-yaml-config.md).
decK talks only to Kong's Admin API. It doesn't care whether Kong runs under Docker or
Podman, so **the YAML format, the workflow and the whole cookbook are identical.** This
page covers what's different on .103. For how to add services, routes, plugins, consumers
and upstreams, use the **Cookbook** in the Ubuntu doc
([link](../ubuntu-docker/deck-yaml-config.md#cookbook)).

> ⚠️ **Apply is a full sync.** Anything in Kong that isn't in
> [`deck/kong.yaml`](deck/kong.yaml) gets **deleted** on the next apply. Make every change
> in the YAML, none with curl.

## What was installed and set up on .103 (2026-10-30)

| Item | Where / what |
|---|---|
| decK **v1.69.0** | `/usr/local/bin/deck` (sha256 checked against `checksums.txt`; SELinux label `bin_t`, fine) |
| Config file | [`rhel-podman/deck/kong.yaml`](deck/kong.yaml): 9 services / routes / rate limits for **.103** |
| Wrapper | [`rhel-podman/deck/kong-config.sh`](deck/kong-config.sh): `validate` / `diff` / `apply` / `backup` / `restore` (same script as Ubuntu) |
| Repo clone | `~/kong_withDB_install_with_noname_integration_ubuntu_docker` on .103 |
| Backups | `~/kong-backups/kong-YYYYMMDD-HHMMSS.yaml` on .103, taken before every apply |

How it was checked on .103:

- After the curl-built Step 8 config, `./kong-config.sh diff` = `0 / 0 / 0`, so the YAML
  matches what's running exactly.
- Round trip: applying a copy with an extra service + route + `response-transformer`
  created 3 entities, and the `X-Managed-By: decK` header came back through the proxy. A
  stray service was then added with curl. Applying the real file deleted all 4 extras, and
  the diff went back to 0.
- After `sudo podman restart kong`, the diff was still 0 (config lives in Postgres).
  SELinux stayed **Enforcing** with no AVC denials.

**Each gateway has its own file.** .103 uses `rhel-podman/deck/kong.yaml` and .91 uses
`ubuntu-docker/deck/kong.yaml`. Today they hold the same 9 apps, but changing one does not
change the other. To make a change on both, edit both files and apply on each host.

### Install steps (Rocky/RHEL)

```bash
sudo dnf -y install git            # if missing
VER=1.69.0                          # latest: https://github.com/Kong/deck/releases
d=$(mktemp -d) && cd "$d"
curl -sSLO https://github.com/Kong/deck/releases/download/v$VER/deck_${VER}_linux_amd64.tar.gz
curl -sSLO https://github.com/Kong/deck/releases/download/v$VER/checksums.txt
grep " deck_${VER}_linux_amd64.tar.gz$" checksums.txt | sha256sum -c -    # must say OK
tar xzf deck_${VER}_linux_amd64.tar.gz deck
sudo install -m 0755 deck /usr/local/bin/deck      # install(1) gives it the right SELinux label
cd / && rm -rf "$d"

deck gateway ping --kong-addr http://localhost:8001    # "Successfully connected to Kong! Kong version: 3.6.1"

cd ~ && git clone https://github.com/mcropsey/kong_withDB_install_with_noname_integration_ubuntu_docker.git
cd kong_withDB_install_with_noname_integration_ubuntu_docker/rhel-podman/deck
./kong-config.sh diff                                  # 0 / 0 / 0 on .103
```

On a brand-new gateway (after Step 7 of [`../kong.md`](../kong.md)),
`./kong-config.sh apply` creates the whole config and replaces Step 8.

## Everyday workflow on .103

```bash
ssh mcropsey@192.168.1.103
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker/rhel-podman/deck
git pull

vi kong.yaml                  # edit (cookbook: ../ubuntu-docker/deck-yaml-config.md#cookbook)
./kong-config.sh validate     # silent = OK
./kong-config.sh diff         # preview creates / updates / DELETES
./kong-config.sh apply        # backs up, shows diff, asks y/N, syncs
sleep 5 && curl -sI -H 'Host: <host>.cropseyit.com' http://localhost/   # router rebuild takes ~5 s
```

Then commit the change. **.103 has no GitHub credentials** (on purpose, so the token isn't
copied to more hosts), so commit and push from a box that does:

- edit and push from .98 (or ubuntu-1..3), then `git pull` on .103 before `apply`, **or**
- run decK remotely from a box with decK installed:
  `KONG_ADDR=http://192.168.1.103:8001 rhel-podman/deck/kong-config.sh apply`
  (backups then land in that box's `~/kong-backups`).

If you'd rather push straight from .103, set up git credentials there the same way as on
ubuntu-1..3.

## RHEL / Podman specifics

| Topic | Note |
|---|---|
| Container commands in the docs | `docker …` in the Ubuntu doc → `sudo podman …` here (e.g. `sudo podman logs kong`) |
| SELinux | Enforcing, nothing needed for decK, or for the Noname image (no bind mount) |
| Custom plugins (e.g. Noname) | code = a **custom image** built with `sudo podman build --format docker` from [`../noname-image/Dockerfile`](../noname-image/Dockerfile), run with `KONG_PLUGINS=bundled,nonamesecurity`. Instance = a `- name: nonamesecurity` entry in `kong.yaml` (not curl). Full steps: [`noname-kong-install-rhel.md`](noname-kong-install-rhel.md) |
| Restart after reboot | needs `podman-restart.service` enabled (done on .103) |
| Admin API exposure | published by Podman/netavark, so **firewalld doesn't filter it**. Bind to `127.0.0.1:8001` if needed |
| Secrets | the repo is public. Use `${{ env "DECK_NAME" }}` in the YAML, never literal keys. Backups in `~/kong-backups` can contain secrets and stay on the host |
