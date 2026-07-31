# M17 Reflector — Dockerized `mrefd`

This repository wraps [`mrefd`](https://github.com/n7tae/mrefd) — the modern M17
open-source reflector daemon — into a parameterized Docker deployment. The goal
is to make bringing up an M17 reflector on a small computer (Raspberry Pi 3/4/5,
Zero 2W, a NUC, or any Linux VPS) a matter of running a wizard and a couple of
`make` targets, rather than compiling from source and hand-editing systemd
units.

Both IPv4 **and** IPv6 are first-class deployment paths — the default posture
avoids NAT entirely so Ham-DHT external-address probing just works on
dual-stack hosts.

---

## Why this exists

M17 is a fully open digital voice protocol for amateur radio. Interoperability
with the DMR / D-STAR / YSF worlds happens through *reflectors*, and `mrefd`
(with its DHT-based peer discovery) is the reference server. But standing one
up today means installing a modern C++ toolchain plus OpenDHT, wiring up
systemd, configuring lighttpd + PHP for the dashboard, and getting a firewall
right. Container packaging collapses that into: fill in a form, run `make up`,
add DNS.

---

## Repository layout

```
.
├── Makefile                    # top-level wrapper - `make help`
├── docker-compose.yml          # mrefd (host network) + dashboard (bridge, dual-stack)
├── docker-compose.bridge.yml   # override: bridge mode for mrefd (Docker Desktop, shared hosts)
├── .env.example                # every configurable knob, with comments
├── docker/
│   ├── mrefd/
│   │   ├── Dockerfile          # multi-arch Debian 12 build
│   │   └── entrypoint.sh       # renders mrefd.cfg from env, then execs mrefd
│   └── dashboard/
│       ├── Dockerfile          # lighttpd + php-fpm + php-dash
│       ├── lighttpd.conf
│       └── entrypoint.sh       # renders config.inc.php from env
├── scripts/
│   └── init.sh                 # interactive setup wizard (`make init`)
├── config/                     # bind-mounted live-editable files (gitignored)
│   ├── mrefd.whitelist         # created by `make init`
│   ├── mrefd.blacklist
│   └── mrefd.interlink
└── mrefd/                      # upstream source as a git submodule
```

---

## Prerequisites

On the deployment host (Raspberry Pi OS 64-bit, Debian 12, or Ubuntu 22.04+):

```bash
# 1. Docker Engine + Compose v2 (script from get.docker.com works on Pi/Debian/Ubuntu)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"     # log out/in for group to take effect

# 2. Git + Make
sudo apt-get install -y git make

# 3. Enable IPv6 in the docker daemon (only if you need bridged IPv6)
#    Edit /etc/docker/daemon.json to include `"ipv6": true` and a fixed-cidr-v6.
#    Not required for the default host-networking layout.
```

Multi-arch cross-builds (from an x86_64 workstation targeting `arm64`/`armv7`
Pi images) additionally need QEMU-user, which the buildx builder pulls in
automatically.

---

## Quickstart

```bash
git clone --recurse-submodules <this-repo-url> m17-reflector
cd m17-reflector

make init            # interactive wizard: callsign, modules, email, ports…
make build-local     # native-arch build, loaded into local docker
make up-dashboard    # start reflector + dashboard
make logs            # follow logs

# open http://<host>:8080/ for the dashboard.
```

Later, when you change something in `.env`:

```bash
make restart         # picks up env changes without rebuilding
```

When you edit `config/mrefd.whitelist`, `config/mrefd.blacklist` or
`config/mrefd.interlink`, `mrefd` picks up changes within seconds — no
restart needed.

---

## Ports & firewall

| Purpose               | Proto | Default port | Direction | Required when                       |
|-----------------------|-------|--------------|-----------|-------------------------------------|
| M17 protocol          | UDP   | 17000        | inbound   | always                              |
| Ham-DHT peer discovery| UDP   | 17171        | inbound   | `MREFD_DHT_ENABLED=true`            |
| Web dashboard (HTTP)  | TCP   | 8080         | inbound   | dashboard profile started           |
| Web dashboard (HTTPS) | TCP   | 443          | inbound   | if you front the dashboard with TLS |

Open the corresponding ports on your router/firewall for **both** IPv4 and
IPv6 if you have dual-stack connectivity. The point of running IPv6 is to
avoid CGNAT and reachability issues that plague residential IPv4.

---

## Networking model

By default, the mrefd service uses `network_mode: host`. This means:

* `mrefd` binds directly on the host's IPv4 and IPv6 wildcards.
* No NAT rewrite → Ham-DHT publishes real reachable addresses without needing
  you to hand-set `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`.
* The `M17_PORT` / `DHT_PORT` values in `.env` are used only by `mrefd` itself
  and to tell you what to open on your firewall.

The dashboard runs on a compose-managed bridge network with an explicit
dual-stack port publish, so it stays cleanly isolated.

**When to use bridge mode instead:** Docker Desktop (macOS/Windows) doesn't
support host networking, and some shared-tenant hosts forbid it. Overlay the
bridge file:

```bash
docker compose -f docker-compose.yml -f docker-compose.bridge.yml up -d
```

In bridge mode you probably want to set `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`
in `.env` to your public addresses, or the DHT will advertise the container's
internal IP.

---

## Configuration reference

Every setting lives in `.env`. The wizard covers the required fields; the file
itself has inline comments for the rest. Grouped for reference:

### Identity (required)

| Var                              | Purpose                                       |
|----------------------------------|-----------------------------------------------|
| `MREFD_CALLSIGN`                 | `M17-XYZ` — must be unused (check dvref.com)  |
| `MREFD_MODULES`                  | Subset of A–Z, one thread per module          |
| `MREFD_COUNTRY`                  | ISO country code                              |
| `MREFD_EMAIL`                    | Admin contact, published on the DHT           |
| `MREFD_DASHBOARD_URL`            | Public URL shown on the DHT record            |
| `MREFD_SPONSOR`                  | Optional club/organization name               |

### Encryption

| Var                              | Purpose                                       |
|----------------------------------|-----------------------------------------------|
| `MREFD_ENCRYPTION_ALLOWED`       | Blank = disallowed everywhere. Or a subset.   |
| `MREFD_LISTEN_ONLY_ALLOW_ENCRYPT`| `true`/`false`                                |

Know your local regulations — most amateur services prohibit encryption over
the air.

### Networking

| Var               | Purpose                                                     |
|-------------------|-------------------------------------------------------------|
| `MREFD_PORT`      | UDP port `mrefd` binds inside the container                 |
| `MREFD_IPV4_BIND` | `0.0.0.0` default. Blank ⇒ IPv6-only.                       |
| `MREFD_IPV6_BIND` | `::` default. Blank ⇒ IPv4-only.                            |
| `MREFD_IPV4_EXT`  | Override auto-detected v4 external address. Rarely needed.  |
| `MREFD_IPV6_EXT`  | Override auto-detected v6 external address. Rarely needed.  |
| `M17_PORT`        | Host-side M17 port (host-mode: same as `MREFD_PORT`)        |
| `DHT_PORT`        | Host-side DHT port                                          |
| `DASHBOARD_PORT`  | Host-side HTTP port for the dashboard                       |

### Ham-DHT

| Var                    | Purpose                                                 |
|------------------------|---------------------------------------------------------|
| `MREFD_DHT_ENABLED`    | `true` to publish/discover peers via DHT                |
| `MREFD_BOOTSTRAP`      | Existing DHT node to bootstrap from                     |

### Build-time (rebuild required)

| Var                | Purpose                             |
|--------------------|-------------------------------------|
| `MREFD_BUILD_DHT`  | Compile DHT support in              |
| `MREFD_BUILD_DEBUG`| Debug symbols + `-DDEBUG`           |

### Dashboard

| Var                    | Purpose                                              |
|------------------------|------------------------------------------------------|
| `DASHBOARD_IPV4`       | Displayed IP. Blank = auto-detect at container start |
| `DASHBOARD_IPV6`       | Displayed IP. `NONE` to hide.                        |
| `DASHBOARD_TZ`         | tz database name (e.g. `America/Phoenix`)            |
| `DASHBOARD_IP_MODE`    | IP privacy on Links/Peers pages                      |
| `DASHBOARD_MODULE_<X>` | Friendly name shown next to module letter `<X>`      |

---

## Interlinking

Edit `./config/mrefd.interlink` on the host — `mrefd` inside the container
picks up changes within a few seconds thanks to the built-in file watcher.

The three interlink formats (DHT-only, legacy IP+port, and pre-1.0 "legacy L"
peers) are described in comments at the top of that file; the wizard seeds a
copy of the upstream template for you.

---

## Multi-arch image builds

`make build-local` builds only for your workstation's architecture and loads
the result into the local docker — this is what you want on a Pi doing its own
build, or for iterative development.

`make build` runs a `buildx` multi-arch build for the platforms listed in
`BUILD_PLATFORMS` (default: `linux/arm64,linux/arm/v7,linux/amd64`). Multi-arch
images don't fit in the local docker daemon — pushing to a registry is the
useful outcome:

```bash
IMAGE_MREFD=ghcr.io/YOU/mrefd:1.0.0 \
IMAGE_DASHBOARD=ghcr.io/YOU/mrefd-dashboard:1.0.0 \
    docker buildx build --push --platform linux/arm64,linux/amd64 \
    --file docker/mrefd/Dockerfile --tag ghcr.io/YOU/mrefd:1.0.0 .
```

or just add `--push` and edit the `Makefile` `build:` recipe.

---

## Updating

Upstream `mrefd` releases happen on the `n7tae/mrefd` repo. To pick up a new
version:

```bash
cd mrefd && git fetch && git checkout <tag-or-main>
cd ..
make build-local
make restart
```

If the release notes call out new options in `example.cfg`, cross-reference
them against `.env.example` and add whatever's missing.

---

## Troubleshooting

* **`mrefd` exits with `MREFD_CALLSIGN is required`** — you skipped `make init`
  or didn't fill in a callsign. Rerun the wizard or edit `.env`.
* **Peers connect but audio doesn't pass** — check that `MREFD_ENCRYPTION_ALLOWED`
  matches the peer for the shared module; a mismatch on encryption support
  silently drops streams.
* **DHT shows your container's internal IP** — you're in bridge mode without
  `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`. Either set those, or switch to the
  default host-networking layout.
* **IPv6 traffic doesn't arrive** — verify your host has native IPv6
  (`curl -6 https://icanhazip.com` inside the container). For bridge mode,
  also make sure `/etc/docker/daemon.json` has `"ipv6": true`.
* **Dashboard shows stale data** — the dashboard reads
  `/var/log/mrefd/mrefd.json` from the shared volume. If the volume was
  recreated, restart both services with `make restart`.

---

## Credits & license

* `mrefd` © 2020–2025 Thomas A. Early N7TAE, GPL — see the submodule.
* php-dash bundled from the same upstream.
* This wrapper: use however helps you get more M17 on the air.
