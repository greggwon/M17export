# Build and publish your own image

Do this if you want to run a build you produced (a fork, a local mrefd
patch, a private registry, or an air-gapped setup).

## 1. Get the full source, with submodules

The build needs the `mrefd/` submodule.

```bash
git clone --recurse-submodules https://github.com/greggwon/M17export.git
cd M17export
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## 2. Log into wherever you'll publish

Whatever registry you use — GitHub Container Registry (ghcr.io), Docker
Hub, AWS ECR, self-hosted `registry:2`, etc.

```bash
# GitHub Container Registry (PAT needs write:packages scope):
echo <YOUR_PAT> | docker login ghcr.io -u <YOUR_GH_USER> --password-stdin
```

## 3. Multi-arch build + push in one command

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

## 4. Point the deployment at your image

Edit `deploy/docker-compose.yml` and change the `image:` line to your
tag:

```yaml
image: ghcr.io/<YOUR_GH_USER>/mrefd:latest
```

Pin a version instead of `latest` per release (`:v1.2.0`, `:2026-08-25`,
a git SHA — whatever your convention is).

## 5. Deploy

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
