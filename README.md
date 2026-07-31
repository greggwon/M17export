# M17 Reflector — Containerized `mrefd`

This project packages [`mrefd`](https://github.com/n7tae/mrefd) — the reference
M17 open-source reflector daemon — as a parameterized, multi-architecture
Docker deployment. The goal is to reduce the effort of standing up an M17
reflector from "install a toolchain, build OpenDHT, hand-edit systemd,
configure lighttpd + PHP" down to "fill in a form, run one `make`".

The primary deployment target is a small always-on Linux computer (Raspberry
Pi 3/4/5, Zero 2W, a NUC, an old ThinkPad in a closet, or any Linux VPS).
IPv4 and IPv6 are equal-footing deployment paths — the default networking
model avoids NAT entirely so Ham-DHT external-address probing "just works"
on dual-stack hosts.

---

## Contents

1. [Why this project exists](#why-this-project-exists)
2. [What you get](#what-you-get)
3. [Repository layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Quickstart](#quickstart)
6. [Networking model (IPv4 + IPv6)](#networking-model-ipv4--ipv6)
7. [Ports & firewall](#ports--firewall)
8. [Configuration reference](#configuration-reference)
9. [Interlinking and DVREF](#interlinking-and-dvref)
10. [Multi-architecture image builds](#multi-architecture-image-builds)
11. [Upstream patch posture](#upstream-patch-posture)
12. [Operational lifecycle](#operational-lifecycle)
13. [Updating](#updating)
14. [Troubleshooting](#troubleshooting)
15. [Related sibling app: MSeven](#related-sibling-app-mseven)
16. [Credits & license](#credits--license)

---

## Why this project exists

**M17** is a fully open digital-voice protocol for amateur radio — free of the
patent-encumbered codecs (AMBE) that gate DMR / D-STAR / YSF. Its long-term
value depends on network *reachability*: the more repeaters, hot-spots, and
reflectors are on the air, the more the mode gets used.

The blocker isn't the protocol; it's the operational overhead. Standing up a
real M17 reflector today means installing a modern C++17 toolchain, building
or installing OpenDHT (the DHT library used for peer discovery), writing
systemd units, configuring lighttpd + PHP for the dashboard, and getting the
firewall right on both IPv4 and IPv6. For an operator who just wants to
export a DMR talkgroup or D-STAR reflector into M17 through
[`mrefd`](https://dvref.com), that overhead is a much bigger barrier than the
radio side of it.

**Containerization collapses that setup into a wizard and a `make up`.** Once
the operator has Docker on any Linux box they already own, this repo turns
their reflector into a reproducible, upgradable, arch-portable service.
That's what unlocks the population of "casual" M17 reflectors that the
network needs to grow.

The dashboards at [dvref.com](https://dvref.com) list a mix of MREFD and URFD
reflectors already interlinked into the M17 ecosystem — this project is aimed
squarely at making it easy to add another one.

---

## What you get

- **A multi-arch Docker image** for `mrefd`, built once and deployable on
  `linux/arm64` (Pi 4/5, Zero 2W 64-bit), `linux/arm/v7` (Pi 3, Zero 2W
  32-bit), and `linux/amd64` (x86_64 servers, mini-PCs).
- **A companion image** running the upstream PHP dashboard behind `lighttpd`.
- **Complete parameterization through a single `.env` file.** Every knob
  exposed by `mrefd.mk` (build-time) and `mrefd.cfg` (run-time), plus the PHP
  dashboard's `config.inc.php`, is an environment variable with a comment
  explaining what it does.
- **An entrypoint script** that renders `mrefd.cfg` from those env vars at
  container start, validates required fields, and refuses to start with
  placeholder values.
- **An interactive wizard** (`make init`) that prompts for the required
  identity/network fields and seeds a working `./config/` directory.
- **Compose profiles** so the dashboard is opt-in (`make up` for headless,
  `make up-dashboard` to add it).
- **Live-editable list files** — `mrefd.whitelist`, `mrefd.blacklist`, and
  `mrefd.interlink` bind-mount from a host directory so `mrefd`'s built-in
  file watcher picks up changes within seconds without a restart.
- **First-class IPv6 support**, including default deployment via
  `network_mode: host` on Linux so real dual-stack traffic reaches `mrefd`
  without any NAT rewriting, and a bridge-mode override for hosts that can't
  do host networking.
- **A build-time patch** for a real bug in upstream `mrefd/users.cpp`
  (documented in [Upstream patch posture](#upstream-patch-posture) below).

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
└── mrefd/                      # upstream source as a git submodule (currently a fork)
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

# 3. (Only if you must run in bridge mode with IPv6)
#    Edit /etc/docker/daemon.json to include `"ipv6": true`, then restart docker.
#    Not required for the default host-networking layout.
```

Multi-arch cross-builds (from an x86_64 workstation targeting `arm64`/`armv7`
Pi images) additionally need QEMU-user, which the buildx builder pulls in
automatically on first use.

For development on macOS: Docker Desktop for **Apple Silicon** (not the
amd64/Rosetta build) or [Colima](https://github.com/abiosoft/colima). Note
that host networking is a Linux-kernel feature — on macOS you'll need the
`docker-compose.bridge.yml` overlay described below.

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

Or, for a total one-shot on a fresh Pi:

```bash
make first           # submodule init + wizard + build + up-dashboard
```

Later, when you change something in `.env`:

```bash
make restart         # picks up env changes without rebuilding
```

When you edit `config/mrefd.whitelist`, `config/mrefd.blacklist`, or
`config/mrefd.interlink`, `mrefd` picks up changes within seconds — no
restart needed.

---

## Networking model (IPv4 + IPv6)

By default the mrefd service uses `network_mode: host`. This means:

- `mrefd` binds directly on the host's IPv4 and IPv6 wildcards.
- No NAT rewrite → Ham-DHT publishes real reachable addresses without you
  having to hand-set `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`.
- The `M17_PORT` / `DHT_PORT` values in `.env` are used by `mrefd` itself and
  as the values you'll open on your firewall — Docker isn't publishing them,
  the container is listening on the host's real ports directly.

The dashboard service runs on a compose-managed bridge network with
`enable_ipv6: true` and dual-stack (IPv4 + IPv6) port publishes, so it stays
cleanly isolated but reachable from both stacks.

**Why this shape:** the whole point of IPv6 for amateur reflectors is to
sidestep the CGNAT and port-forwarding hoops that residential IPv4 keeps
inflicting on operators. If a Pi at your house has a real IPv6 address and no
usable IPv4 inbound, host networking + IPv6 gets you on the air; NAT-bridged
mode does not.

**When to use bridge mode for mrefd instead.** Docker Desktop (macOS/Windows)
doesn't support host networking, and some shared-tenant hosts forbid it.
Overlay the bridge file:

```bash
docker compose -f docker-compose.yml -f docker-compose.bridge.yml \
    --profile dashboard up -d
```

In bridge mode you probably want to set `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`
in `.env` to your public addresses, or the DHT will advertise the container's
internal IP.

---

## Ports & firewall

| Purpose               | Proto | Default port | Direction | Required when                       |
|-----------------------|-------|--------------|-----------|-------------------------------------|
| M17 protocol          | UDP   | 17000        | inbound   | always                              |
| Ham-DHT peer discovery| UDP   | 17171        | inbound   | `MREFD_DHT_ENABLED=true`            |
| Web dashboard (HTTP)  | TCP   | 8080         | inbound   | dashboard profile started           |
| Web dashboard (HTTPS) | TCP   | 443          | inbound   | if you front the dashboard with TLS |

Open the corresponding ports on your router/firewall for **both** IPv4 and
IPv6 wherever you have dual-stack connectivity.

---

## Configuration reference

Every setting lives in `.env`. The wizard covers the required fields; the
file itself has inline comments for the rest. Grouped for reference:

### Identity (required)

| Var                              | Purpose                                       |
|----------------------------------|-----------------------------------------------|
| `MREFD_CALLSIGN`                 | `M17-XYZ` — must be unused (check dvref.com)  |
| `MREFD_MODULES`                  | Subset of A–Z, one processing thread per module |
| `MREFD_COUNTRY`                  | ISO 2-letter country code                     |
| `MREFD_EMAIL`                    | Admin contact, published on the DHT           |
| `MREFD_DASHBOARD_URL`            | Public URL shown on the DHT record            |
| `MREFD_SPONSOR`                  | Optional club/organization name (no `=` char) |

### Encryption

| Var                              | Purpose                                       |
|----------------------------------|-----------------------------------------------|
| `MREFD_ENCRYPTION_ALLOWED`       | Blank = disallowed everywhere. Or a subset.   |
| `MREFD_LISTEN_ONLY_ALLOW_ENCRYPT`| `true`/`false`                                |

**Know your local regulations** — most amateur services prohibit encryption
over the air.

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
| `MREFD_DHT_ENABLED`    | `true` to publish/discover peers via DHT (recommended)  |
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

## Interlinking and DVREF

An M17 reflector by itself is useful. Interlinked reflectors are what makes
the network. Every entry you add to `./config/mrefd.interlink` peers your
reflector to another `mrefd` (or a `urfd` gateway that exports an XLX / DMR /
D-STAR / YSF room into M17). The three interlink formats — DHT-only,
legacy IP+port, and pre-1.0 "legacy L" peers — are described in comments at
the top of that file; the wizard seeds a copy of the upstream template for
you.

- The community list of active reflectors and interlink gateways is at
  **[https://dvref.com](https://dvref.com)**. Once your reflector is on the
  DHT and publicly reachable, register it there so other operators find it.
- Interlink relationships are bidirectional: both sides must list each other.
  When using DHT, that's a two-line change on each side. When using the
  legacy IP+port form, both sides need to keep the encryption capabilities of
  the shared module aligned or traffic will silently drop.
- Edits to `./config/mrefd.interlink` are picked up by the running reflector
  within a few seconds — no restart.

---

## Multi-architecture image builds

`make build-local` builds only for your workstation's native architecture and
loads the result into the local Docker daemon. This is what you want on a Pi
doing its own build, or for iterative development.

`make build` runs a `buildx` multi-arch build for the platforms listed in
`BUILD_PLATFORMS` (default: `linux/arm64,linux/arm/v7,linux/amd64`).
Multi-arch images don't fit in the local docker daemon — pushing to a
registry is the useful outcome:

```bash
IMAGE_MREFD=ghcr.io/greggwon/mrefd:1.0.0 \
IMAGE_DASHBOARD=ghcr.io/greggwon/mrefd-dashboard:1.0.0 \
    docker buildx build --push --platform linux/arm64,linux/amd64 \
    --file docker/mrefd/Dockerfile \
    --tag ghcr.io/greggwon/mrefd:1.0.0 .
```

Notes on architectures:
- `linux/arm64` is the fastest to build (native on Apple Silicon and Pi 4/5).
- `linux/amd64` cross-compiles cleanly under QEMU on Apple Silicon.
- `linux/arm/v7` (32-bit ARM) is the slowest cross-compile and exposes bugs
  that 64-bit builds hide — see the next section.

---

## Upstream patch posture

The Dockerfile applies exactly one patch to the upstream `mrefd` source
before compiling: a `sed` substitution on `users.cpp:53` that changes `>>`
(right shift) to `>` (greater-than). The clause was intended to trim the
last-heard list when it exceeds `LASTHEARD_USERS_MAX_SIZE` (=40) entries,
but with `>>` in place:

- On 64-bit hosts, `size_t` is 64 bits, so `size() >> 40` is almost always 0
  and the resize never runs — the list grows unbounded (silent bug).
- On 32-bit ARM (`linux/arm/v7`), `size_t` is 32 bits, so shifting by 40
  exceeds the type width and hits `-Werror=shift-count-overflow`, breaking
  the build.

The fix is a one-character change in the C++ source; the sed patch is
documented in `docker/mrefd/Dockerfile` with a comment explaining the
reasoning. A PR fixing this upstream at `n7tae/mrefd` has been opened from
the `greggwon/mrefd` fork on branch `fix-lastheard-shift-overflow`; once
merged and the submodule is bumped to that commit, the sed becomes a no-op
(harmless — it just won't match anything).

**Why the patch stays even after upstream merges:** it keeps the image
correct regardless of which mrefd revision the submodule happens to be
pinned at. Removing it only when the submodule is guaranteed to be
post-merge avoids a fragile "rebuild first, then update Dockerfile" ordering.

---

## Operational lifecycle

```
make help              # menu of everything
make init              # interactive wizard: write .env + populate ./config
make build-local       # native-arch build, loaded into local docker
make build             # multi-arch build (buildx), stays in build cache
make up                # start reflector (headless)
make up-dashboard      # start reflector + dashboard
make down              # stop everything (volumes preserved)
make restart           # restart to pick up .env changes
make logs              # follow all logs
make logs-mrefd        # just mrefd
make logs-dashboard    # just dashboard
make shell             # shell inside the mrefd container
make status            # container status
make clean             # down + remove named volumes (DHT state, logs)
make prune             # clean + remove local images
make first             # one-shot: submodules + init + build-local + up-dashboard
```

---

## Updating

**Bumping `mrefd`:**

```bash
cd mrefd
git fetch upstream
git checkout upstream/master        # or a specific release tag
cd ..
git add mrefd                       # record the new submodule SHA
make build-local
make restart
```

If a new `mrefd` release adds options to `example.cfg`, cross-check them
against `.env.example` and add whatever's missing there and in
`docker/mrefd/entrypoint.sh`.

**Bumping the Debian base image:** the Dockerfile pins `debian:12-slim`.
Rebuild periodically to pick up security updates in the base OS:

```bash
docker buildx build --pull ...      # or `make build-local` after `docker pull debian:12-slim`
```

---

## Troubleshooting

- **`mrefd` exits with `MREFD_CALLSIGN is required`** — you skipped `make
  init` or didn't fill in a callsign. Rerun the wizard or edit `.env`.
- **Peers connect but audio doesn't pass** — check that
  `MREFD_ENCRYPTION_ALLOWED` matches the peer for the shared module; a
  mismatch on encryption support silently drops streams.
- **DHT shows your container's internal IP** — you're in bridge mode without
  `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`. Either set those, or switch to the
  default host-networking layout.
- **IPv6 traffic doesn't arrive** — verify your host has native IPv6
  (`curl -6 https://icanhazip.com` from inside the container). For bridge
  mode, also confirm `/etc/docker/daemon.json` has `"ipv6": true` and Docker
  has been restarted since.
- **Dashboard shows stale data** — the dashboard reads
  `/var/log/mrefd/mrefd.json` from the shared volume. If the volume was
  recreated, restart both services with `make restart`.
- **`linux/arm/v7` build fails with `shift-count-overflow`** — you're
  building against a mrefd revision that predates the users.cpp fix and the
  sed patch didn't match. Confirm the Dockerfile's sed line still matches
  the source in your submodule.

---

## Related sibling app: MSeven

**MSeven** is an Apple-native (iOS/macOS) M17 client, sold via the App Store,
that speaks M17 directly to reflectors like the one this repo helps you
stand up. This project exists in part to expand the population of reflectors
that MSeven users have to connect to — the two projects are complementary:
MSeven is the operator's client on the radio side, this project is the
server infrastructure that gives that client something to talk to.

---

## Credits & license

- `mrefd` and the bundled PHP dashboard: © 2020–2025 Thomas A. Early **N7TAE**,
  GPL — see the [`mrefd/`](./mrefd) submodule.
- The `gomrefdash` dashboard alternative is by **DU8BL**:
  <https://github.com/DU8BL/gomrefdash>.
- The M17 protocol is developed by the [M17 Project](https://m17project.org/).
- This container packaging and its tooling: use however helps you get more
  M17 on the air.
