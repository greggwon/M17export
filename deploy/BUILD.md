# Build and publish your own image

There are two ways to produce your own image:

- **Option A: customize the published image.** Write a short Dockerfile
  that starts `FROM ghcr.io/greggwon/mrefd` and adds your files. You don't
  need the source tree or submodules, nothing is compiled, and it builds
  in seconds. Use this for site-specific images such as a field-kit image
  with its `site.json`, interlink file and extra tools baked in.
- **Option B: build from source.** Compile mrefd from the submodule. Use
  this for a fork, a patch to mrefd itself, a platform the published image
  doesn't cover, or an air-gapped setup.

---

## Option A: customize the published image

### What the published image provides

`ghcr.io/greggwon/mrefd:latest` is a public multi-arch image. You can pull
it without logging in.

| Property    | Value                                                         |
|-------------|---------------------------------------------------------------|
| Platforms   | `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/386`     |
| User        | `mrefd` (uid/gid 1000)                                        |
| Entrypoint  | `/usr/bin/tini -- /entrypoint.sh`                             |
| Binaries    | `/usr/local/bin/mrefd`, `/usr/local/bin/m17-advertise`        |
| Config dir  | `/etc/mrefd` (owned by `mrefd`)                               |
| State / log | `/var/lib/mrefd`, `/var/log/mrefd`                            |
| Base        | `debian:12-slim`                                              |

`linux/arm/v7` covers 32-bit Raspberry Pi OS on a Pi 3 or Zero 2W. Tags
published before it was added to the release build contain only the other
three platforms, so check what a tag actually contains:

```bash
docker buildx imagetools inspect ghcr.io/greggwon/mrefd:latest
```

### A1. Write a Dockerfile

Make a directory anywhere. It doesn't need to be inside this repo. Put the
files you want to bake in next to the Dockerfile:

```
my-field-image/
├── Dockerfile
├── site.json          # mDNS advertisement record (optional)
└── mrefd.interlink    # default interlink file (optional)
```

```dockerfile
FROM ghcr.io/greggwon/mrefd:latest

# Installing packages requires root; switch back afterwards.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends iputils-ping tcpdump \
 && rm -rf /var/lib/apt/lists/*

# Bake in the mDNS advertisement record. The entrypoint uses
# /etc/mrefd/site.json automatically when it exists.
COPY --chown=mrefd:mrefd site.json /etc/mrefd/site.json

# Default interlink file. A bind mount at run time still overrides it.
COPY --chown=mrefd:mrefd mrefd.interlink /etc/mrefd/mrefd.interlink

# Defaults for settings. Values in mrefd.env / env_file override these.
ENV MREFD_ADVERTISE_NETWORK_TYPE=residential

# Always end as the unprivileged user.
USER mrefd
```

Rules:

- **Don't override `ENTRYPOINT`.** It renders `mrefd.cfg` from the
  environment, starts mrefd, and starts the advertiser 10 seconds later.
  To change what it does, `COPY` a modified `entrypoint.sh` over
  `/entrypoint.sh` instead.
- **Always end with `USER mrefd`.** mrefd and its state directories expect
  that user.
- **Use `--chown=mrefd:mrefd`** on files the reflector may need to write
  or that the entrypoint checks.
- **Never bake private keys** (`server.key`, `client.key`) into an image
  you push to a registry, and certainly not a public one. Mount
  `config/tls/` at run time instead, as `deploy/docker-compose.yml`
  already does.
- **Values that differ per node stay out of the image.** Callsign, email
  and the like go in `mrefd.env`; the image holds only what every node of
  that kind shares.

### A2. Build it for this machine

```bash
cd my-field-image
docker build -t my-mrefd:field .
```

Docker pulls the variant of the base image that matches your host
(`arm64` on a Pi 4/5 or Apple Silicon, `amd64` on a PC or VPS).

Check it before deploying:

```bash
# Runs as mrefd, entrypoint unchanged
docker image inspect my-mrefd:field --format '{{.Config.User}} {{json .Config.Entrypoint}}'

# The advertiser sees the baked-in record
docker run --rm --entrypoint /usr/local/bin/m17-advertise my-mrefd:field \
    --config /etc/mrefd/site.json --designator XYZ --dry-run
```

### A3. Build multi-arch and push (optional)

If the image runs on more than one kind of host, build all of them at
once and push to your registry. No compiling happens, so this is fast even
under emulation.

```bash
echo <YOUR_PAT> | docker login ghcr.io -u <YOUR_GH_USER> --password-stdin
docker buildx create --use --name m17-builder 2>/dev/null || true
docker buildx build \
    --platform linux/amd64,linux/arm64,linux/arm/v7 \
    --tag ghcr.io/<YOUR_GH_USER>/mrefd-field:latest \
    --push .
```

Only list platforms that the base image publishes (see the table above).

### A4. Point the deployment at it

In `deploy/docker-compose.yml`, change the `image:` line:

```yaml
image: my-mrefd:field                               # local build (A2)
# or
image: ghcr.io/<YOUR_GH_USER>/mrefd-field:latest    # pushed (A3)
```

Then start it as usual:

```bash
docker compose up -d
docker compose logs -f
```

### Keeping it current

Your image is a snapshot of the base image as it was when you built it. To
pick up a new release, rebuild with `--pull` so Docker fetches the latest
base:

```bash
docker build --pull -t my-mrefd:field .
docker compose up -d
```

For repeatable builds, pin the base to a release tag or a digest instead
of `latest`:

```dockerfile
FROM ghcr.io/greggwon/mrefd@sha256:<digest-from-imagetools-inspect>
```

---

## Option B: build from source

### 1. Get the full source, with submodules

The build needs the `mrefd/` submodule.

```bash
git clone --recurse-submodules https://github.com/greggwon/M17export.git
cd M17export
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Log into wherever you'll publish

Whatever registry you use — GitHub Container Registry (ghcr.io), Docker
Hub, AWS ECR, self-hosted `registry:2`, etc.

```bash
# GitHub Container Registry (PAT needs write:packages scope):
echo <YOUR_PAT> | docker login ghcr.io -u <YOUR_GH_USER> --password-stdin
```

### 3. Multi-arch build + push in one command

```bash
docker buildx create --use --name m17-builder 2>/dev/null || true
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --file docker/mrefd/Dockerfile \
    --tag ghcr.io/<YOUR_GH_USER>/mrefd:latest \
    --push \
    .
```

This produces one manifest list covering both x86-64 (EC2, most VPS, x86
mini-PCs) and arm64 (Pi 4/5, Graviton, arm64 VPS). Docker on the target
host automatically pulls the right variant.

To also target 32-bit ARM (Pi 3, Zero 2W on the 32-bit OS), add
`linux/arm/v7` to the `--platform` list. Slower to build; skip unless
you actually need it.

### 4. Point the deployment at your image

Edit `deploy/docker-compose.yml` and change the `image:` line to your
tag:

```yaml
image: ghcr.io/<YOUR_GH_USER>/mrefd:latest
```

Pin a version instead of `latest` per release (`:v1.2.0`, `:2026-08-25`,
a git SHA — whatever your convention is).

### 5. Deploy

On the deployment host, follow the `README.md` in this directory. The
only difference from the "pull the public image" path is that they'll
`docker login` to *your* registry (with a PAT that has `read:packages`),
and the `image:` line points at your build.

---

## Testing the build locally before publishing

Single-arch, native, no push — useful for iterating on mrefd source
changes:

```bash
docker build \
    --file docker/mrefd/Dockerfile \
    --tag m17export/mrefd:test \
    .
```

Then either point `deploy/docker-compose.yml` at `m17export/mrefd:test`
for a local docker-compose run, or `docker save | ssh <host> docker load`
to move the image to a target that can't reach your registry.

## Troubleshooting

- **`buildx: docker: 'buildx' is not a docker command`** — install
  `docker-buildx-plugin` (Debian/Ubuntu) or upgrade Docker Engine to
  20.10+.
- **`ERROR: multiple platforms feature is currently not supported for
  docker driver`** — you skipped `docker buildx create --use`. The
  default `docker` driver can't do multi-arch; the `docker-container`
  driver that `create` sets up can.
- **Build fails on `linux/arm/v7` with `shift-count-overflow`** — you're
  building against a mrefd revision that predates the users.cpp fix.
  The `docker/mrefd/Dockerfile` includes a `sed` patch that handles this
  for supported revisions; if it doesn't match, bump the submodule to
  a newer commit.
- **`unauthorized` on push** — the PAT doesn't have `write:packages`.
  (Read is not enough for push.)
