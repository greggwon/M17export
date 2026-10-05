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

Fill in at minimum: `MREFD_CALLSIGN`, `MREFD_MODULES`, `MREFD_COUNTRY`,
`MREFD_EMAIL`, `MREFD_DASHBOARD_URL`. Everything else is optional.

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
PutDHTConfig() successful
```

To stop: `docker compose down`. To update to a newer image later:
`docker compose pull && docker compose up -d`.

---

## Ports to open on your firewall

| Purpose                   | Proto | Default port |
|---------------------------|-------|--------------|
| M17 protocol              | UDP   | 17000        |
| TLS interlink (optional)  | TCP   | 17000        |
| Ham-DHT                   | UDP   | 17171        |
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

## Optional: TLS interlink

The community default for reflector interlinks is IP-based UDP peering,
and that keeps working exactly as it always has. TLS is an *additional*
option for cases where it solves a specific problem — a peer with a
variable public IP, a private mesh you don't want on dvref, etc.

- Undecided whether TLS is worth it for a given peering?
  → [`INTERLINK-CHOICES.md`](INTERLINK-CHOICES.md) walks through when
    each model fits and gives talking points for the two-way sign-off.
- Ready to set TLS up? → [`CERTS.md`](CERTS.md) covers cert creation,
  distribution, verification, and rotation.
- Full protocol design (wire format, handshake, threat model):
  `../docs/tls-interlink-design.md` in the source repo.

## Building your own image

To make your own image, see [`BUILD.md`](BUILD.md) in this directory:

- **Option A** customizes the published image: a short Dockerfile
  `FROM ghcr.io/greggwon/mrefd` adds your `site.json`, default interlink
  file or tools. No source and no compiling; it builds in seconds.
- **Option B** builds from source, for a fork, an mrefd patch, or an
  air-gapped setup.
