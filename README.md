# M17export — containerized M17 reflectors, with field-to-hub TLS links

This project packages [`mrefd`](https://github.com/n7tae/mrefd), the M17
reflector daemon, as a Docker image for a Raspberry Pi, a mini-PC or a VPS,
plus a web dashboard. It adds one thing upstream mrefd doesn't have: a
**field node** on a changing or NATed uplink (a go-kit, a vehicle, an event
site) can hold an authenticated TLS link to a **hub** reflector at a fixed
address, so its users are on the wider M17 network wherever it is.

---

## Status

**Works, and tested end to end** (hub and field containers, including
simulated slow, high-latency uplinks):

- **TLS field-to-hub links:** voice and data both ways. The link survives
  the field node changing address, notices a dead link through TCP
  keepalive, and shuts down cleanly. Hubs refuse keys they don't know.
- **Key management:** a script for each step (`scripts/tls-*.sh`, also
  inside the image). Registering, changing or revoking an operator's key
  on a hub takes effect within seconds, with no restart.
- **Watching links:** clear `link UP` / `link DOWN` log lines with the
  reason, a **TLS Links** dashboard page, and a status badge on every
  page.
- **Slow links:** voice is kept current rather than queued, and data still
  gets through when voice can't. See
  [Slow links: voice or data](#slow-links-voice-or-data).
- **mDNS / Bonjour advertisement** (`_m17._udp`), on by default, so MSeven
  and other clients find a reflector on the local network.

**Not decided yet:** whether hubs also publish on Ham-DHT. Field nodes run
without it. Both builds work (`MREFD_BUILD_DHT=false`, the default, or
`true`).

**Not done:**
- **IPv6 address literals in `tls:` lines.** Use a DNS name instead.
- **Changing a field node's hub line takes a restart.** Hub-side changes
  apply live.

## Which document to read

| You want to… | Read |
|---|---|
| Run a reflector, or link a field node to a hub | this README (below) |
| Deploy from the published image without the source | [`deploy/README.md`](deploy/README.md) |
| Look something up about TLS keys and certificates | [`deploy/CERTS.md`](deploy/CERTS.md) |
| Decide between plain UDP peering and TLS for a link | [`deploy/INTERLINK-CHOICES.md`](deploy/INTERLINK-CHOICES.md) |
| Read the long-form operator manual (mDNS in depth, field kits) | [`docs/index.html`](docs/index.html) |
| Understand the TLS link protocol as built | [`docs/tls-interlink-design.md`](docs/tls-interlink-design.md) |
| Build or publish your own image | [`deploy/BUILD.md`](deploy/BUILD.md) |

---

## Quickstart: run a reflector

On a Linux host with Docker
([prerequisites](#prerequisites)):

```bash
git clone --recurse-submodules https://github.com/greggwon/M17export.git
cd M17export
make init            # asks for the callsign (M17-XYZ), modules (B,C,D), ports
make build-local     # builds the images for this machine
make up-dashboard    # starts the reflector and the dashboard
make logs            # watch it start: "Reflector M17-XYZ started and listening"
```

The dashboard is at `http://<host>:8080/`. Open **UDP 17000** inbound on
the firewall (and **TCP 17000** if this will be a hub). Settings live in
`.env`; after changing them, run `make restart`.

---

## Link a field node to a hub

A **hub** has a fixed address and accepts field nodes. A **field node**
dials out to the hub from wherever it is, so its own address doesn't
matter. They trust each other through certificates exchanged once:

- The hub has one key.
- Each field **operator** has one key, used by all of that operator's
  nodes.
- Each node links one module, and the hub names it after the operator's
  callsign and that module, e.g. `W5ABC-B`.

Run the commands from the M17export directory on each machine. They
work on Linux, and on macOS with `brew install openssl@3`. Or run them
from the image with no tools installed; see
[`deploy/CERTS.md`](deploy/CERTS.md).

**On the hub, once:**

```bash
scripts/tls-genkey.sh --role hub --identity M17-HUB
```

This prints a fingerprint. Give `config/tls/server.crt` and the
fingerprint to the field operators. Make sure **TCP 17000** is open
inbound.

**Each field operator, once:**

```bash
scripts/tls-genkey.sh --identity W5ABC
```

Send `config/tls/client.crt` (**never the `.key`**) to the hub operator,
with the modules you want and the fingerprint it printed. If you run
several nodes, copy the whole `config/tls/` directory to each of them.

**On the hub, for each operator:**

```bash
scripts/tls-add-peer.sh --cert W5ABC.crt --modules B,C
```

The hub applies this within seconds; no restart. Read the printed
fingerprint back to the operator to confirm the file arrived intact.

**On each field node:**

```bash
scripts/tls-add-hub.sh --hub M17-HUB --host hub.example.org --module B --cert M17-HUB.crt
make restart
```

**Check it:** `make logs` shows
`link UP: to 'M17-HUB' ... as 'W5ABC-B'` on the field node, and
`link UP: node 'W5ABC-B'` on the hub. Both dashboards show it on the
**TLS Links** page, and `scripts/tls-list-peers.sh` lists it on either
side.

**Later:**

| To… | Run (on the hub unless noted) |
|---|---|
| Change which modules an operator may use | `scripts/tls-add-peer.sh --cert W5ABC.crt --modules C` (drops their node on B) |
| Revoke an operator | `scripts/tls-remove-peer.sh --identity W5ABC` (drops all their nodes at once) |
| See who's registered and connected | `scripts/tls-list-peers.sh` |
| Check from a field node that the hub is reachable and genuine | `scripts/tls-verify.sh --host hub.example.org` |
| Replace the hub's key | `scripts/tls-rotate-server-cert.sh --identity M17-HUB`, then every field operator reruns `tls-add-hub.sh` with the new cert |

If the link doesn't come up, the field node's log says why. For example,
"hub rejected us: our key isn't registered there" means the hub operator
still needs to run `tls-add-peer.sh` with your key. Other messages and
fixes are under [Troubleshooting](#troubleshooting).

---

## Watching links

- **Dashboard.** Every page has a TLS badge:

  | Colour | Meaning |
  |---|---|
  | Green | Links up |
  | Yellow | Voice falling behind (delay growing) |
  | Red | A link is down, or voice can't keep up (use data) |
  | Grey | Waiting for nodes |

  The **TLS Links** page shows, for each link:
  - its state, and how long it has been in that state;
  - its address;
  - frames in and out;
  - voice delay, with whether it's steady or growing;
  - stale voice dropped;
  - the last problem.
- **Logs** (`make logs`):
  - `link UP` and `link DOWN` lines say how long the link was up, why it
    went down (keepalive timeout, peer reset, peer sent DISCONNECT, hub
    rejected us, and so on) and the frame counts.
  - While a link is down, the reconnect attempts are logged, with how
    long it has been down.
- **`scripts/tls-list-peers.sh`** prints the same picture in a terminal.

## Slow links: voice or data

This is radio: audio must stay *current*, not arrive complete and late.

- **What gets dropped.** Each link drops voice that has waited more than
  200 ms to go out (`MREFD_TLS_MAX_AUDIO_MS`), so listeners hear the
  present. Data (packet mode) is never dropped for age.
- **Delay alone is fine.** A long but steady delay, such as a satellite
  hop, stays green. Only a link slower than the voice causes drops.
- **Voice needs about 31 kbit/s each way.** Each M17 voice frame grows from
  61 to about 150 bytes once TLS, TCP and IP headers are added.
- **When voice breaks up, switch to data.** Signs that a link can't carry
  voice are:
  - broken audio;
  - a yellow or red badge;
  - "can't keep up with voice" in the log.

  Data still gets through on that link.

Voice delivered in testing, over a simulated uplink:

| Uplink | Voice delivered |
|---|---|
| 64 kbit/s, 300 ms | 100% |
| 48 kbit/s, 600 ms | 99–100% |
| 40 kbit/s, 600 ms | 100% |
| 24 kbit/s, 600 ms | ~75% |
| 12 kbit/s, 300 ms | ~55–60% |
| 8 kbit/s, 600 ms | ~40% |

Data was tested on the 24, 12 and 8 kbit/s links and got through
complete on all three.

Field nodes never give up connecting: TCP retries run their full course
over slow or lossy links, then the node retries on its own. Keepalives
notice a link that silently died in about 5 minutes
(`MREFD_TLS_KEEPALIVE`; see [TLS interlink settings](#tls-interlink)).

---

## Reference

- [Why this project exists](#why-this-project-exists)
- [What you get](#what-you-get)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Networking model (IPv4 + IPv6)](#networking-model-ipv4--ipv6)
- [Bonjour / mDNS discovery](#bonjour--mdns-discovery)
- [Ports & firewall](#ports--firewall)
- [Configuration reference](#configuration-reference)
- [Interlinking and DVREF](#interlinking-and-dvref)
- [Multi-architecture image builds](#multi-architecture-image-builds)
- [Upstream patch posture](#upstream-patch-posture)
- [Operational lifecycle](#operational-lifecycle)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Related sibling app: MSeven](#related-sibling-app-mseven)
- [Credits & license](#credits--license)

---

## Why this project exists

**M17** is a fully open digital-voice protocol for amateur radio. It is
free of the patent-encumbered codecs (AMBE) that gate DMR, D-STAR and YSF.
Its value grows with reachability: the more repeaters, hotspots and
reflectors there are on the air, the more the mode gets used.

The barrier is setup, not the protocol. Running an M17 reflector by hand
means:

- installing a C++17 toolchain;
- building OpenDHT;
- writing systemd units;
- configuring lighttpd and PHP for the dashboard;
- getting the firewall right for IPv4 and IPv6.

This repo turns all of that into a wizard and `make up`.

---

## What you get

- **Images for several architectures:** a `mrefd` image for `linux/arm64`,
  `linux/arm/v7` and `linux/amd64`, plus a dashboard image (lighttpd +
  PHP).
- **One `.env` file for every setting,** each with a comment. The
  entrypoint turns it into `mrefd.cfg` when the container starts.
- **Optional dashboard:** `make up` runs headless, `make up-dashboard`
  adds the dashboard.
- **List files you can edit live:** `mrefd.whitelist`, `mrefd.blacklist`
  and `mrefd.interlink` live in `config/`, and mrefd picks up edits within
  seconds.
- **Real dual-stack networking:** host networking on Linux, so IPv6 and
  IPv4 reach mrefd without NAT. There is a bridge-mode override for hosts
  that can't use host networking.
- **TLS field-to-hub links,** the key-management scripts, and dashboard
  status for them.
- **A fix for an upstream bug** in `mrefd/users.cpp`, applied at build
  time (see [Upstream patch posture](#upstream-patch-posture)).

---

## Repository layout

```
.
├── Makefile                    # `make help`
├── docker-compose.yml          # mrefd (host network) + dashboard (bridge, dual-stack)
├── docker-compose.bridge.yml   # override: bridge mode for mrefd (Docker Desktop, shared hosts)
├── .env.example                # every setting, with comments
├── docker/
│   ├── mrefd/                  # Dockerfile, entrypoint.sh (renders mrefd.cfg from env)
│   └── dashboard/              # lighttpd + php-fpm + php-dash
├── scripts/
│   ├── init.sh                 # setup wizard (`make init`)
│   └── tls-*.sh                # TLS key management (also in the image as tls-*)
├── config/                     # yours, gitignored; mounted into the container
│   ├── mrefd.whitelist / mrefd.blacklist / mrefd.interlink
│   └── tls/                    # server.* (hub), client.* (field), peers/, hubs/
├── deploy/                     # run from the published image, without the source
├── docs/                       # operator manual (index.html), TLS design
├── tools/m17-advertise/        # mDNS / Bonjour advertiser
└── mrefd/                      # mrefd source (submodule: the greggwon fork with TLS links)
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
```

Multi-arch cross-builds (from an x86_64 workstation targeting `arm64`/`armv7`
Pi images) additionally need QEMU-user, which the buildx builder pulls in
automatically on first use.

For development on macOS: Docker Desktop for **Apple Silicon** (not the
amd64/Rosetta build) or [Colima](https://github.com/abiosoft/colima). Note
that host networking is a Linux-kernel feature — on macOS you'll need the
`docker-compose.bridge.yml` overlay described below.

---

## Networking model (IPv4 + IPv6)

By default the mrefd service uses `network_mode: host`. This means:

- `mrefd` binds directly on the host's IPv4 and IPv6 wildcards.
- No NAT rewrite → peers and the mDNS advertisement see real reachable
  addresses without you having to hand-set `MREFD_IPV4_EXT` / `MREFD_IPV6_EXT`.
- The `M17_PORT` value in `.env` is used by `mrefd` itself and
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
in `.env` to your host's addresses, or mDNS will advertise the container's
internal IP.

### macOS Docker Desktop quirks

Docker Desktop's Mac implementation of `network_mode: host` does **not**
actually give the container access to the host's network stack — it silently
becomes bridged. That means on macOS you must use the bridge overlay:

```
docker compose -f docker-compose.yml -f docker-compose.bridge.yml \
    --profile dashboard up -d
```

Two related quirks that will bite you on Docker Desktop for Mac:

1. **UDP dual-stack publish bug.** Declaring the same UDP port as both
   `0.0.0.0` and `[::]` results in only the IPv6 socket actually binding;
   IPv4 sends hit ICMP port unreachable ("Connection refused" in the
   client). The bridge compose file works around this by publishing UDP
   ports on IPv4 only. TCP is unaffected and stays dual-stack.
2. **UDP 5353 (mDNS) is owned by macOS.** The host's own mDNSResponder
   already binds it, so container publishing collides. Bonjour advertisement
   from inside the container cannot reach the LAN on macOS. Set
   `MREFD_ADVERTISE_ENABLED=false` and run `tools/m17-advertise` natively on
   the host if you need MSeven to see the reflector during Mac-side
   development.

Neither quirk affects real Linux deployments (Pi, VPS, bare metal). Host
networking works there and mDNS multicast flows to the LAN natively.

---

## Bonjour / mDNS discovery

The container includes `tools/m17-advertise`, a small Go binary that
publishes the reflector as a `_m17._udp` service so that MSeven (and any
Bonjour-aware M17 client) can auto-populate its connection list from
whatever LAN the operator is on. Field ARES kits get local discovery for
free — bring the Pi up on the event Wi-Fi and every MSeven device on that
network sees it.

TXT record fields mirror one entry from MSeven's
[sites.json](http://mseven.wonderly.org/mseven/sites.json.gz) `reflectors[]`
schema. The advertiser fills the TXT from a combination of:

- Standard mrefd env vars (`MREFD_CALLSIGN`, `MREFD_MODULES`, `MREFD_PORT`,
  `MREFD_SPONSOR`, `MREFD_COUNTRY`, `MREFD_DASHBOARD_URL`,
  `MREFD_ENCRYPTION_ALLOWED`, `MREFD_IPV4_EXT`, `MREFD_IPV6_EXT`) —
  auto-derived (designator, slug, ipv4/ipv6 auto-detected when unset)
- Optional MSeven-schema fields: `MREFD_ADVERTISE_NAME`,
  `MREFD_ADVERTISE_DESCRIPTION`, `MREFD_ADVERTISE_NETWORK_TYPE`
- Optional bind-mounted `MREFD_ADVERTISE_CONFIG` JSON (a single
  `reflectors[]` entry) as a base layer that env vars overlay on top of

The advertiser starts 10 seconds after `mrefd` binds so the service is
already accepting connections by the time it becomes discoverable. Disable
with `MREFD_ADVERTISE_ENABLED=false`.

Standalone (non-container) use for testing or non-mrefd reflectors:

```
tools/m17-advertise --config path/to/entry.json                    # from JSON
tools/m17-advertise --designator TUL --slug m17-tul --port 17000 \  # or flags
                    --modules "A,B,C,D,E" --sponsor "..." --url "..."
```

Individual flags override values loaded from `--config`. See
`tools/m17-advertise/main.go` `--help` for the full list.

---

## Ports & firewall

| Purpose                    | Proto | Default port | Direction | Required when                                        |
|----------------------------|-------|--------------|-----------|------------------------------------------------------|
| M17 protocol               | UDP   | 17000        | inbound   | always                                               |
| TLS links from field nodes | TCP   | 17000        | inbound   | on a hub (field nodes only dial out)                 |
| Bonjour / mDNS advertise   | UDP   | 5353         | local LAN | `MREFD_ADVERTISE_ENABLED=true` (default)             |
| Web dashboard (HTTP)       | TCP   | 8080         | inbound   | dashboard profile started                            |
| Web dashboard (HTTPS)      | TCP   | 443          | inbound   | if you front the dashboard with TLS                  |

Open the corresponding ports on your router/firewall for **both** IPv4 and
IPv6 wherever you have dual-stack connectivity. Note that UDP 5353 is
LAN-only (multicast) — no router configuration needed, but it does need to
reach the container's network namespace; see the macOS quirks section below.

---

## Configuration reference

Every setting lives in `.env`. The wizard covers the required fields; the
file itself has inline comments for the rest. Grouped for reference:

### Identity

Only the first two are required. The country, email and dashboard URL
are required with Ham-DHT on, because they go on the public listing.

| Var                              | Purpose                                       |
|----------------------------------|-----------------------------------------------|
| `MREFD_CALLSIGN`                 | `M17-XYZ`. Must be unused (check dvref.com)   |
| `MREFD_MODULES`                  | e.g. `B,C,D` (`BCD` works too). One processing thread per module |
| `MREFD_COUNTRY`                  | ISO 2-letter country code                     |
| `MREFD_EMAIL`                    | Admin contact                                 |
| `MREFD_DASHBOARD_URL`            | Dashboard URL, advertised over mDNS           |
| `MREFD_SPONSOR`                  | Optional club/organization name (no `=` char) |

### Encryption

| Var                              | Purpose                                       |
|----------------------------------|-----------------------------------------------|
| `MREFD_ENCRYPTION_ALLOWED`       | Blank = disallowed everywhere. Or modules, e.g. `C,D` |
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
| `DASHBOARD_PORT`  | Host-side HTTP port for the dashboard                       |

### Ham-DHT

Field nodes run without Ham-DHT: they reach the network through their
hub, and they're never published. Whether hubs should publish on Ham-DHT
is still undecided, so both builds are supported:

- `MREFD_BUILD_DHT` and `MREFD_DHT_ENABLED` default to `false`.
- For a DHT hub, set both to `true` and fill in the country, email and
  dashboard URL.

Two catches with a DHT build:
- It won't run with `MREFD_DHT_ENABLED=false`.
- It won't start without internet access unless `MREFD_IPV4_EXT` is set.

### Build-time (rebuild required)

| Var                | Purpose                             |
|--------------------|-------------------------------------|
| `MREFD_BUILD_DHT`  | Compile DHT support in (default off)|
| `MREFD_BUILD_DEBUG`| `-DDEBUG` packet dumps (debug symbols are always included) |

### Dashboard

| Var                    | Purpose                                              |
|------------------------|------------------------------------------------------|
| `DASHBOARD_IPV4`       | Displayed IP. Blank = auto-detect at container start |
| `DASHBOARD_IPV6`       | Displayed IP. `NONE` to hide.                        |
| `DASHBOARD_TZ`         | tz database name (e.g. `America/Phoenix`)            |
| `DASHBOARD_IP_MODE`    | IP privacy on Links/Peers pages                      |
| `DASHBOARD_MODULE_<X>` | Friendly name shown next to module letter `<X>`      |

### Bonjour / mDNS advertiser

| Var                            | Purpose                                                                 |
|--------------------------------|-------------------------------------------------------------------------|
| `MREFD_ADVERTISE_ENABLED`      | `true`/`false`. Default `true`. Set false on macOS/Windows Docker Desktop |
| `MREFD_ADVERTISE_NAME`         | Optional human-readable name (MSeven schema `name`)                     |
| `MREFD_ADVERTISE_DESCRIPTION`  | Optional description; HTML permitted                                    |
| `MREFD_ADVERTISE_NETWORK_TYPE` | `hosting` / `business` / `residential`                                  |
| `MREFD_ADVERTISE_CONFIG`       | Container path to a `reflectors[]`-schema JSON to use as base           |

### TLS interlink

None of these are needed for the usual setup. The keys are found in
`config/tls/`, and lines in `mrefd.interlink` turn links on (see
[Link a field node to a hub](#link-a-field-node-to-a-hub)). Empty means
default.

| Var                        | Default | Purpose |
|----------------------------|---------|---------|
| `MREFD_TLS_SERVER_CERT` / `_KEY` | `config/tls/server.crt` / `.key` if present | The hub's certificate and key |
| `MREFD_TLS_CLIENT_CERT` / `_KEY` | `config/tls/client.crt` / `.key` if present | A field node's (operator's) certificate and key |
| `MREFD_TLS_PORT`           | `MREFD_PORT` (17000) | TCP port the hub listens on |
| `MREFD_TLS_BIND_ADDR`      | `MREFD_IPV6_BIND`, else `0.0.0.0` | Address the hub listens on |
| `MREFD_TLS_TIMESTAMP_SKEW` | `300` | How far apart the two ends' clocks may be, in seconds. Use NTP |
| `MREFD_TLS_MAX_AUDIO_MS`   | `200` | Voice waiting longer than this to go out is dropped, not sent late. Raise for bursty links (LTE, busy Wi-Fi) |
| `MREFD_TLS_DATA_QUEUE_KB`  | `1024` | Most packet-mode data that may queue behind a slow link |
| `MREFD_TLS_KEEPALIVE`      | `60,30,8` | TCP keepalive: idle, interval, count (seconds), or `off`. Notices a dead link in about 5 min |
| `MREFD_TLS_USER_TIMEOUT`   | `0` (off) | Drop the link when sent data has gone unacknowledged this many seconds |

How the protocol works:
[docs/tls-interlink-design.md](docs/tls-interlink-design.md).

---

## Interlinking and DVREF

An M17 reflector by itself is useful. Interlinked reflectors are what makes
the network. Every entry you add to `./config/mrefd.interlink` peers your
reflector to another `mrefd` (or a `urfd` gateway that exports an XLX / DMR /
D-STAR / YSF room into M17). Without Ham-DHT, UDP peers are listed by IP
and port rather than looked up by callsign. The formats are described in
comments at the top of that file. Field nodes link to a hub with TLS
instead (see [Link a field node to a hub](#link-a-field-node-to-a-hub)).

- The community list of active reflectors and interlink gateways is at
  **[https://dvref.com](https://dvref.com)** — useful for finding a public
  reflector's address to interlink with.
- Interlink relationships are bidirectional: both sides must list each other,
  and both sides need to keep the encryption capabilities of the shared
  module aligned or traffic will silently drop.
- Edits to `./config/mrefd.interlink` are picked up by the running reflector
  within a few seconds — no restart. The exception is a field node's TLS
  hub line (`tls:`), which takes effect when the node restarts.

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
make clean             # down + remove named volumes (state, logs)
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

**TLS links.** The field node's log (`make logs`) says what's wrong:

| Log says | Fix |
|---|---|
| `hub rejected us: our key isn't registered there` | Hub operator: `scripts/tls-add-peer.sh --cert <your client.crt> --modules ...` |
| `hub rejected us: module B isn't allowed for our key at the hub` | Hub operator: add the module with `tls-add-peer.sh --modules` |
| `hub rejected us: our clock and the hub's differ too much` | Turn on NTP at both ends (they must agree within 5 minutes) |
| `hub rejected us: BIRTH signature didn't verify` | The hub has an old copy of your certificate: send the current one; hub runs `tls-add-peer.sh --force` |
| `can't resolve '...'` or `TCP connect to ... failed: ...` | Check the host name in the `tls:` line, and that TCP 17000 is open inbound on the hub |
| `TLS handshake failed: the hub's certificate doesn't match our servercert: pin ...` | The hub's key changed: get its new `server.crt` and rerun `tls-add-hub.sh` |
| entrypoint: `... isn't readable by mrefd` | The key file belongs to another user: run the `chown` it prints |
| `can't keep up with voice: dropped N stale voice frame(s)` | The link is slower than voice needs (~31 kbit/s): use data (packet mode) on it |
| `mrefd.interlink registers operator keys, but MREFD_TLS_SERVER_CERT ... aren't set` | The hub has no key yet: `scripts/tls-genkey.sh --role hub ...`, then restart |

`scripts/tls-verify.sh --host <hub>` checks from a field node that the hub
is reachable, and shows which hub certificate it presents.

**Everything else:**

- **`mrefd` exits with `MREFD_CALLSIGN is required`** — you skipped `make
  init` or didn't fill in a callsign. Rerun the wizard or edit `.env`.
- **Peers connect but audio doesn't pass** — check that
  `MREFD_ENCRYPTION_ALLOWED` matches the peer for the shared module; a
  mismatch on encryption support silently drops streams.
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
- **MSeven says "Connection refused" on UDP 17000 from macOS** — Docker
  Desktop's UDP dual-stack publish bug. Use `docker-compose.bridge.yml`
  (which already publishes UDP on IPv4 only) and verify with
  `lsof -iUDP:17000` — you should see a `com.docke ... IPv4 ... UDP *:17000`
  entry. If it only shows IPv6, the container isn't reachable via IPv4.
- **MSeven never discovers the reflector on Wi-Fi from Docker Desktop
  (Mac/Windows)** — expected. Docker Desktop can't publish mDNS multicast
  to the host LAN. Set `MREFD_ADVERTISE_ENABLED=false` and run
  `tools/m17-advertise` natively on the host, or deploy on a real Linux
  host with host networking.
- **mDNS SRV target shows `hostname.local.local.`** — old advertiser build.
  Rebuild `tools/m17-advertise`; the fix uses `RegisterProxy` with a
  cleaned hostname.
- **Advertiser publishes but MSeven shows the address as
  `@ip%interface`** — same as above; MSeven's fallback formatting for a
  doubled-`.local.local.` SRV target.
- **Bind-mounted file becomes an empty directory on the host** —
  Docker's classic bind-mount trap: if the host path doesn't exist when
  the container starts, Docker creates a directory. Stop the container,
  remove the empty directory, `touch` the file into place, restart.

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
