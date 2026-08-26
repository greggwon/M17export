# Deploy an M17 Reflector

Five steps. About 3 minutes on a fresh Linux host.

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

## 3. Log into the image registry (private image, needs a PAT)

Create a GitHub Personal Access Token with the `read:packages` scope:
<https://github.com/settings/tokens>

```bash
echo <YOUR_PAT> | docker login ghcr.io -u <YOUR_GH_USER> --password-stdin
```

## 4. Configure

```bash
cp mrefd.env.example mrefd.env
$EDITOR mrefd.env
```

Fill in at minimum: `MREFD_CALLSIGN`, `MREFD_MODULES`, `MREFD_COUNTRY`,
`MREFD_EMAIL`, `MREFD_DASHBOARD_URL`. Everything else is optional.

Note: the callsign must be exactly `M17-XYZ` (three A–Z/0–9 chars after
`M17-`) and must not be already listed at <https://dvref.com>. If you're
just testing before going public, pick something distinctive.

## 5. Start it

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

- **`unauthorized` on pull** — `docker login ghcr.io` never happened, or the
  PAT doesn't have `read:packages`.
- **`no matching manifest for linux/amd64`** — the image was pushed for a
  single non-amd64 arch. Rebuild multi-arch from the source repo.
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

If you'd rather build the image yourself (a fork, a private registry, or
air-gapped) instead of pulling the public tag, see [`BUILD.md`](BUILD.md)
in this directory.
