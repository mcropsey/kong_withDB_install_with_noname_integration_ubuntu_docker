# Kong (DB mode) + Noname integration — Ubuntu/Docker **and** RHEL/Podman, YAML-managed

Fork of [kong_withDB_install_with_noname_integration](https://github.com/mcropsey/kong_withDB_install_with_noname_integration),
which targets Rocky Linux (RHEL-family) with rootful Podman. This repo adds:

- an **Ubuntu 24.04 + Docker** version of both guides, in [`ubuntu-docker/`](ubuntu-docker/)
- a record of the **Rocky Linux + Podman** deployment done with the original guide, in [`rhel-podman/`](rhel-podman/)
- **YAML as the source of truth** for both gateways: `kong.yaml` applied with [decK](https://github.com/Kong/deck)

## Gateways

| Host | Platform | Built with | Config (source of truth) |
|---|---|---|---|
| **192.168.1.91** (`ubuntu-1`) | Ubuntu 24.04.5 + Docker 29.1.3 | [`ubuntu-docker/kong-ubuntu-docker.md`](ubuntu-docker/kong-ubuntu-docker.md) | [`ubuntu-docker/deck/kong.yaml`](ubuntu-docker/deck/kong.yaml) |
| **192.168.1.100** (`hv-rocky-linux-3`) | Rocky Linux 9.8 + Podman 5.8.2 | [`kong.md`](kong.md) + Noname, converted to YAML + Noname image on 10-30 ([`rhel-podman/kong-rhel-100.md`](rhel-podman/kong-rhel-100.md)) | [`rhel-podman/deck-100/kong.yaml`](rhel-podman/deck-100/kong.yaml) |
| **192.168.1.103** (`hv-rocky-linux-6`) | Rocky Linux 10.2 + Podman 5.8.2 | [`kong.md`](kong.md) (notes: [`rhel-podman/kong-rhel-103-deployment.md`](rhel-podman/kong-rhel-103-deployment.md)) | [`rhel-podman/deck/kong.yaml`](rhel-podman/deck/kong.yaml) |

All three run Kong 3.6.1 in DB mode (Postgres 16), proxy on `:80` and Admin API on `:8001`,
with the same 9 services / 9 routes / 9 rate limits. Each gateway has **its own
`kong.yaml`**, so a change applied on one does not touch the others.

**Noname runs on .100 only.** It uses Noname's **custom-image** method: Kong runs from
`kong-noname:3.6-5.0.1` ([`noname-image/Dockerfile`](noname-image/Dockerfile)), and the
plugin is turned on by `- name: nonamesecurity` in `deck-100/kong.yaml`. .91 and .103 run
the stock `kong:3.6` image without Noname.

## Changing config (both hosts)

```bash
cd <repo>/<ubuntu-docker|rhel-podman>/deck
vi kong.yaml && ./kong-config.sh diff && ./kong-config.sh apply
```

Apply is a **full sync**: anything not in the YAML is deleted. How-to and cookbook (services,
routes, plugins, consumers, upstreams, rollback):
[`ubuntu-docker/deck-yaml-config.md`](ubuntu-docker/deck-yaml-config.md). RHEL/Podman
differences: [`rhel-podman/deck-yaml-config-rhel.md`](rhel-podman/deck-yaml-config-rhel.md).

## Files

| Path | Platform | What |
|---|---|---|
| [`kong.md`](kong.md) | Rocky + Podman | original base-gateway guide (written for .104, used for .103) |
| [`noname_kong_install.md`](noname_kong_install.md) | Rocky + Podman | original Noname plugin guide (folder mount + curl, .104), superseded by the two below |
| [`noname-image/Dockerfile`](noname-image/Dockerfile) | both | `kong:3.6` + the Noname plugin built in (the vendor's Docker method) |
| [`rhel-podman/noname-kong-install-rhel.md`](rhel-podman/noname-kong-install-rhel.md) | Rocky + Podman | Noname on .103: build the image, recreate the container, turn it on in `kong.yaml` |
| [`rhel-podman/kong-rhel-100.md`](rhel-podman/kong-rhel-100.md) | Rocky + Podman | **.100**: conversion to YAML + Noname image, how to change config and rebuild the image, rollback |
| [`rhel-podman/deck-100/`](rhel-podman/deck-100/) | Rocky + Podman | `kong.yaml` for .100 (includes `nonamesecurity`) + `kong-config.sh` |
| [`rhel-podman/kong-recreate-podman.sh`](rhel-podman/kong-recreate-podman.sh) | Rocky + Podman | recreate `kong` from a given image with the same settings; auto-rollback if it doesn't come up |
| [`rhel-podman/kong-rhel-103-deployment.md`](rhel-podman/kong-rhel-103-deployment.md) | Rocky + Podman | what was done on .103 and how it differs from `kong.md` (SELinux kept enforcing, firewalld kept running, `podman-restart.service`) |
| [`rhel-podman/deck-yaml-config-rhel.md`](rhel-podman/deck-yaml-config-rhel.md) | Rocky + Podman | decK install and YAML workflow on .103 |
| [`rhel-podman/deck/`](rhel-podman/deck/) | Rocky + Podman | `kong.yaml` for .103 + `kong-config.sh` |
| [`ubuntu-docker/kong-ubuntu-docker.md`](ubuntu-docker/kong-ubuntu-docker.md) | Ubuntu + Docker | Kong 3.6 + Postgres 16 install, ops |
| [`ubuntu-docker/noname-kong-install-ubuntu-docker.md`](ubuntu-docker/noname-kong-install-ubuntu-docker.md) | Ubuntu + Docker | Noname on .91: build the image, recreate the container, turn it on in `kong.yaml` |
| [`ubuntu-docker/deck-yaml-config.md`](ubuntu-docker/deck-yaml-config.md) | any | **decK how-to + cookbook** (shared by both hosts) |
| [`ubuntu-docker/deck/`](ubuntu-docker/deck/) | Ubuntu + Docker | `kong.yaml` for .91 + `kong-config.sh` |
| [`ubuntu-docker/configure-kong.sh`](ubuntu-docker/configure-kong.sh) | any | original curl-based Step 8 setup (now replaced by `kong-config.sh apply`) |

## Verified (2026-10-30)

On every gateway:

- Kong 3.6.1 with the database reachable
- every route answers through the proxy (jenkins → 403, which is Jenkins' own anonymous-access reply)
- the gateway is reachable from the LAN
- config survives a `kong` container restart
- `kong-config.sh diff` = 0 / 0 / 0
- a decK round trip (add via YAML, then remove a stray curl-made service) works

On .103, SELinux stayed **Enforcing** with no AVC denials.
