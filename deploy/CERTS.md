# Certificates for the TLS interlink

**Before you go further:** you may not need TLS at all. The community
default for reflector interlinks is IP-based UDP peering, and that
continues to work fine — TLS is additive, not a replacement. If you
haven't already decided that TLS solves a specific problem for this
peering, read [`INTERLINK-CHOICES.md`](INTERLINK-CHOICES.md) first.

---

There are three certificates in play for any TLS interlink:

1. **Server cert** on the *home* reflector — presented on incoming TLS so
   field peers know they're talking to the right server.
2. **Client cert** on the *field* reflector — presented on outbound TLS
   and used by the field to sign its BIRTH message.
3. **Peer registration files** on the home reflector — one PEM per field
   peer, dropped in `config/tls/peers/` so the home knows which field
   identities to accept.

The current model uses **self-signed Ed25519 certs** for all three. A
CA-signed model (one trust anchor at the home, signed field certs) is
described at the end as a future direction.

---

## Trust model at a glance

```
+-------------------+                           +--------------------+
|  Field reflector  |     TLS handshake         |  Home reflector    |
|                   | <-----------------------> |                    |
|  * client.crt     |     (mutually visible)    |  * server.crt      |
|  * client.key     |                           |  * server.key      |
|  * home.pem       |                           |  * peers/          |
|    (pinned)       |                           |    W5GGW-B.pub.pem |
+-------------------+                           +--------------------+

Home trusts field: home matches the incoming TLS peer's cert fingerprint
                   against the file at config/tls/peers/<IDENTITY>.pub.pem
Field trusts home: field pins the exact server cert file (home.pem)
                   as the ONLY trust anchor
```

No public CA is involved. Every trust decision is explicit and
per-connection.

---

## Generating certs

The container ships `scripts/tls-genkey.sh` (also available in the
M17export source repo). One invocation per identity.

### Home operator

```bash
# From the M17export repo (or wherever tls-genkey.sh lives):
scripts/tls-genkey.sh \
    --identity M17-HOM \
    --role home \
    --out /path/to/deploy/config/tls/server
```

Produces `server.crt` (public, distribute) and `server.key` (private,
0600). Also prints the SPKI SHA-256 fingerprint — publish that alongside
the cert so field operators can verify what they downloaded.

Distribute `server.crt` out-of-band to every field operator (email, git
repo, your website). No secret material leaves the home.

### Field operator

```bash
scripts/tls-genkey.sh \
    --identity W5GGW-B \
    --role field \
    --out /path/to/deploy/config/tls/client
```

Produces `client.crt` (public, send to home admin) and `client.key`
(private, 0600, stays on the field box). Prints the fingerprint.

Also fetch the home's `server.crt` from wherever it's published, save
it as `config/tls/home.pem` on the field box, and set
`MREFD_TLS_HOME_CERT=/etc/mrefd/tls/home.pem` in `mrefd.env`.

### Home operator registers the field's cert

Home operator receives `client.crt` from the field, saves it as
`config/tls/peers/W5GGW-B.pub.pem`, and adds a line to
`config/mrefd.interlink`:

```
W5GGW-B  BCD  key:/etc/mrefd/tls/peers/W5GGW-B.pub.pem
```

mrefd hot-reloads the interlink file within seconds — no restart needed.

---

## Generating without `tls-genkey.sh` (openssl directly)

If you don't have the helper script handy:

```bash
# Ed25519 self-signed cert, 10-year validity, Subject CN = identity
openssl req -x509 -newkey ed25519 -nodes \
    -days 3650 \
    -subj "/CN=W5GGW-B" \
    -addext "subjectAltName=DNS:W5GGW-B" \
    -keyout client.key -out client.crt

chmod 0600 client.key

# Print the SPKI SHA-256 fingerprint (matches what mrefd stores internally)
openssl x509 -in client.crt -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl base64
```

Same steps for the home's `server.crt` / `server.key` — just change the
`--identity` / CN.

---

## Verifying a cert someone sent you

Before dropping a received `client.crt` into `config/tls/peers/`, sanity
check it:

```bash
# Subject CN must match the identity you agreed on
openssl x509 -in client.crt -noout -subject

# Key algorithm should say ED25519
openssl x509 -in client.crt -noout -text | grep 'Public Key Algorithm'

# Compare fingerprint against what the sender told you out-of-band
openssl x509 -in client.crt -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary | openssl base64
```

If any of those don't match expectations, do NOT install the cert.

---

## Server-cert distribution

You have to get `server.crt` to every field operator via a channel that
can't be MITM'd back at you. Options in decreasing operator-friendliness:

- **Signed HTTPS**: publish `server.crt` on your reflector's dashboard
  site under a real CA-issued HTTPS cert. Field operators `curl` it.
  Easiest. TLS itself protects you.
- **DVREF / M17 community listing**: publish the SPKI fingerprint next
  to your `M17-XXX` listing. Field operators install the cert from
  anywhere they like, verify the fingerprint before trusting.
- **git repo**: push `server.crt` to a public repo the field operators
  clone. GitHub's HTTPS + repo signing protects the download.
- **Direct handoff**: at a club meeting, over ham radio (voice the
  fingerprint), or via a signed email. Least convenient, best for a
  small tight-knit group.

Whichever channel — always publish the fingerprint too, so operators can
verify the file's SPKI matches independently.

---

## Rotation

### Field rotates its key

1. Field: `scripts/tls-genkey.sh --identity <same> --role field --out … --force`
2. Field sends new `client.crt` to home.
3. Home: `scripts/tls-add-peer.sh --identity <same> --cert client.crt \
   --modules BCD --force` (or just replace the file and let mrefd
   hot-reload).
4. Field restarts mrefd; new cert is in effect on the next connect.

### Home rotates its key

Big deal — every field has to install the new `server.crt`.

1. Home: `scripts/tls-rotate-server-cert.sh --identity M17-HOM`
2. Publish the new `server.crt` and fingerprint via your channel.
3. Every field operator downloads and replaces `home.pem` on their box.
4. Home: `docker compose restart mrefd` when everyone's had a chance to
   update. Any field still holding the old cert will fail TLS validation
   until they update.

Keep the old key material for a grace period so operators can complete
migration in their own time.

### Revoking a specific peer

Home: `scripts/tls-remove-peer.sh --identity <identity>`

That deletes the peer's cert file, strips the interlink line, and (via
the admin socket / iptables fallback) drops any live session for the
identity. Effective immediately. See `docs/tls-interlink-design.md §7.3`
for the sequence.

---

## Future direction: CA-signed field certs

The self-signed-per-peer model above scales fine for tens of field
peers — the home's `peers/` directory grows linearly with membership.
For larger deployments (a whole ARES section, hundreds of operators) a
CA-signed model would be cleaner:

- Home operator maintains a **CA cert** and CA private key.
- Field operator generates a keypair and a **CSR** (certificate signing
  request) with their callsign in the Subject CN.
- Field emails the CSR to the home admin.
- Home admin signs the CSR with the CA key, produces `client.crt`, sends
  it back.
- Field box holds `client.crt` + `client.key` + a pinned `home.pem` (same
  as today).
- Home mrefd is configured with **one** trust anchor: the CA cert. Any
  incoming TLS peer whose cert chains to that CA — and whose BIRTH
  identity matches its cert's CN — is accepted, without needing an
  individual `peers/<IDENTITY>.pub.pem` file.

This is a strict superset of the current model — self-signed peers keep
working; a CA anchor just adds an additional acceptance path.

**Cost:** the CA private key becomes very valuable (compromise = attacker
signs any callsign). Revocation of individual field certs requires CRL
or short-lived certs — neither trivial. Not enabled by default; when
implemented it will be behind a `MREFD_TLS_TRUST_CA=` env var so
operators who want per-peer registration keep it.

Design details will land in `docs/tls-interlink-design.md` when this
work is scheduled.
