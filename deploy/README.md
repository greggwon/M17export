# Deploy an M17 Reflector

Four steps. About 2 minutes on a fresh Linux host.

## 1. Prereqs (once per host)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker                            # or log out and back in
```

## 2. Grab this directory

Any way you like. Fresh clone:

```bash
git clone https://github.com/greggwon/M17export.git
cd M17export/deploy
```

Or copy just the `deploy/` folder to the host.

## 3. Configure

```bash
cp mrefd.env.example mrefd.env
$EDITOR mrefd.env
```

Fill in `MREFD_CALLSIGN` and `MREFD_MODULES` (e.g. `B,C,D`). Everything
else is optional.

Note: the callsign must be exactly `M17-XYZ` (three A–Z/0–9 chars after
`M17-`) and must not be already listed at <https://dvref.com>. If you're
just testing before going public, pick something distinctive.

## 4. Start it

```bash
docker compose up -d
docker compose logs -f
```

Success looks like:

```
Reflector M17-XYZ started and listening
```

To stop: `docker compose down`. To update to a newer image later:
`docker compose pull && docker compose up -d`.

---

## Ports to open on your firewall

| Purpose                   | Proto | Default port |
|---------------------------|-------|--------------|
| M17 protocol              | UDP   | 17000        |
| TLS links from field nodes (hubs only) | TCP | 17000 |
| mDNS advertisement (LAN)  | UDP   | 5353         |

## When something breaks

- **`unauthorized` on pull** — the image was flipped back to private and
  you're not a package collaborator. Contact the maintainer or build
  your own per [`BUILD.md`](BUILD.md).
- **`no matching manifest for linux/arm/v7`** — you're pulling a tag
  published before 32-bit ARM was added to the release build. Pull
  `:latest`, check the tag with
  `docker buildx imagetools inspect ghcr.io/greggwon/mrefd:<tag>`, or build
  from source per [`BUILD.md`](BUILD.md) Option B.
- **`no matching manifest`** for any other platform — the image was pushed
  without that architecture. Rebuild multi-arch from the source repo.
- **`Is a directory` on any of the three list files** — Docker created a
  bind-mount target as a directory. This dir already has real files for
  those; if you deleted them, `touch config/mrefd.{whitelist,blacklist,interlink}`.
- **Reflector can't be reached from the internet** — check that UDP 17000
  is actually open on your firewall / security group / router. For AWS
  EC2: the VPC's Security Group needs an inbound UDP 17000 rule.

## Optional: link field nodes to a hub over TLS

A field node (a go-kit, vehicle or event site) holds an authenticated TLS
link to a hub at a fixed address, so its own address doesn't matter. The
key scripts are inside the image, so this directory is all you need. Run
them from this `deploy/` directory:

```bash
# shorthand for this session
tls() { docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/etc/mrefd" -v "$PWD:/work" -w /work \
        --entrypoint "tls-$1" ghcr.io/greggwon/mrefd:latest "${@:2}"; }
```

**Hub, once:** `tls genkey --role hub --identity M17-HUB`. Give
`config/tls/server.crt` to field operators, and open TCP 17000 inbound.

**Each field operator, once:** `tls genkey --identity W5ABC`. Send
`config/tls/client.crt` (never the `.key`) to the hub operator. Copy
`config/tls/` to each of your nodes.

**Hub, per operator (live, no restart):**
`tls add-peer --cert W5ABC.crt --modules B,C`

**Each field node:**
`tls add-hub --hub M17-HUB --host hub.example.org --module B --cert M17-HUB.crt`,
then `docker compose restart mrefd`.

**Check:** `docker compose logs mrefd | grep link`, the dashboard's
**TLS Links** page, or `tls list-peers`. Revoke with
`tls remove-peer --identity W5ABC`.

- What each step does, rotation, and doing it by hand:
  [`CERTS.md`](CERTS.md).
- Whether a given link should be TLS or plain UDP peering:
  [`INTERLINK-CHOICES.md`](INTERLINK-CHOICES.md).
- Slow links: voice needs about 31 kbit/s over TLS. If audio breaks up,
  use data (packet mode); see "Slow links" in the top-level
  [README](../README.md).

## Building your own image

To make your own image, see [`BUILD.md`](BUILD.md) in this directory:

- **Option A** customizes the published image: a short Dockerfile
  `FROM ghcr.io/greggwon/mrefd` adds your `site.json`, default interlink
  file or tools. No source and no compiling; it builds in seconds.
- **Option B** builds from source, for a fork, an mrefd patch, or an
  air-gapped setup.
