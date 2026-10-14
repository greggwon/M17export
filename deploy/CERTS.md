# TLS keys and certificates

Reference for operators setting up TLS links between field nodes and a hub.
Not sure you need TLS? UDP interlinks still work and stay the default; see
[`INTERLINK-CHOICES.md`](INTERLINK-CHOICES.md). Protocol details are in
[`docs/tls-interlink-design.md`](../docs/tls-interlink-design.md).

## Who makes which key

| Who            | Key name                          | Files (in `config/tls/`) | How many |
|----------------|-----------------------------------|--------------------------|----------|
| Hub operator   | reflector callsign, e.g. `M17-HUB` | `server.crt`, `server.key` | one per hub |
| Field operator | bare callsign, e.g. `W5ABC`        | `client.crt`, `client.key` | one per operator, copied to all their nodes |

- Each field node links one module per hub line. The hub sees it as
  `CALLSIGN-MODULE` (`W5ABC-B`), so one key covers all of an operator's nodes.
- Keys are self-signed Ed25519. There is no CA.
- The hub accepts a node when its certificate's fingerprint matches a
  registered certificate and the module it asks for is allowed for that key.
  The node trusts only the hub certificate it was given.
- Clocks must agree within 5 minutes (`MREFD_TLS_TIMESTAMP_SKEW`): run NTP on
  both ends.

## What to send, and what never to send

- Send the **`.crt`** only. Field operators send `client.crt` to the hub
  operator; the hub operator sends `server.crt` to each field operator.
- **Never send a `.key` file.** Nobody else needs it, including the hub.
- Check every certificate you receive by comparing its **fingerprint** with
  the sender by phone or in an email you trust. `tls-genkey`, `tls-add-peer`
  and `tls-add-hub` all print it. Don't install a certificate whose
  fingerprint doesn't match.

## Hub setup

```bash
scripts/tls-genkey.sh --role hub --identity M17-HUB   # prints the fingerprint
```

Give `config/tls/server.crt` and the fingerprint to the field operators.
Open **TCP 17000** inbound on the hub's firewall (UDP 17000 as usual).

For each field operator, when their `client.crt` arrives:

```bash
scripts/tls-add-peer.sh --cert W5ABC.crt --modules B,C
```

This copies the cert to `config/tls/peers/W5ABC.pub.pem` and adds
`W5ABC  B,C  key:/etc/mrefd/tls/peers/W5ABC.pub.pem` to `mrefd.interlink`.
mrefd picks it up within seconds; no restart. Adding the first key starts the
TLS listener. The callsign comes from the certificate; `--identity W5ABC`
is optional and must match if given.

## Field setup

Once per operator, on any machine:

```bash
scripts/tls-genkey.sh --identity W5ABC   # send client.crt (never client.key) to the hub operator
```

Copy the whole `config/tls/` directory to each node. Then on each node:

```bash
scripts/tls-add-hub.sh --hub M17-HUB --host hub.example.org --module B --cert M17-HUB.crt
make restart      # or: docker compose restart mrefd
```

This copies the hub cert to `config/tls/hubs/M17-HUB.crt` and adds
`M17-HUB  B  tls:hub.example.org:17000  servercert:/etc/mrefd/tls/hubs/M17-HUB.crt`.
`--host` takes `name` or `name:port` (default 17000). Use a DNS name; IPv6
literals aren't supported. Changes to a node's `tls:` lines take effect only
after restarting that node. `--remove --hub M17-HUB` drops the link.

## Checking

- Dashboard "TLS Links" page, and the badge on every page.
- `make logs` shows `link UP` (or `link DOWN ...` with the reason).
- `scripts/tls-list-peers.sh`: on a hub, each key with its modules,
  fingerprint and connected nodes; on a field node, each hub and its state.
- `scripts/tls-verify.sh --host hub.example.org --expect-fingerprint <fp>`:
  checks the hub is reachable and is the hub you expect. Whether the hub
  accepts *your* key shows in the node's log ("hub rejected us: key not
  registered", "module not allowed", "clock skew").

## Running the scripts

- All scripts take `--config <dir>`: the reflector's config directory (the one
  mounted at `/etc/mrefd`). Default: the repo's `config/`, or `/etc/mrefd`
  inside the image. `tls-verify` has no `--config`; it only talks to the hub.
- Callsigns and modules may be lowercase; modules may be `B,C`, `BC` or `"b c"`.
- **macOS:** `/usr/bin/openssl` is LibreSSL and can't make Ed25519 keys. Run
  `brew install openssl@3`; the scripts find it automatically.
- **No OpenSSL at all:** run the scripts from the image (every script is there
  without the `.sh`):

  ```bash
  docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/etc/mrefd" \
      --entrypoint tls-genkey ghcr.io/greggwon/mrefd:latest --identity W5ABC
  ```

## `config/tls` layout

```
config/tls/                 mounted read-only at /etc/mrefd/tls
├── server.crt, server.key  hub's own key
├── client.crt, client.key  field operator's key (same on all their nodes)
├── peers/W5ABC.pub.pem     hub: one per registered operator
└── hubs/M17-HUB.crt        field: pinned certificate of each hub
```

`config/mrefd.interlink` is mounted separately at `/etc/mrefd/mrefd.interlink`.
Both `docker-compose.yml` files mount `config/tls`. The entrypoint uses the
`server.*` and `client.*` files automatically; set
`MREFD_TLS_SERVER_CERT/KEY` or `MREFD_TLS_CLIENT_CERT/KEY` only to point
somewhere else. Keys are mode 0600. The container runs as uid 1000; if it
can't read a key it stops and prints the `chown` command to run.

## Revoking and changing access (hub)

All of these are live; no restart.

- **Revoke an operator's key:** `scripts/tls-remove-peer.sh --identity W5ABC`.
  Every node using that key is disconnected within seconds and refused from
  then on.
- **Drop one module:** rerun `tls-add-peer.sh` with the modules they keep,
  e.g. `--cert W5ABC.crt --modules B`. Nodes on the removed module are
  disconnected.
- **Retire one node:** same as dropping its module. The operator's other
  nodes carry on. (On the node itself: `tls-add-hub.sh --remove --hub M17-HUB`.)

## Rotating keys

**Operator key** (lost, leaked or replaced):

1. Operator: `scripts/tls-genkey.sh --identity W5ABC --force`, then copy the
   new `config/tls/client.*` to every node and restart them.
2. Operator sends the new `client.crt` to the hub operator, with the new
   fingerprint.
3. Hub: `scripts/tls-add-peer.sh --cert W5ABC.crt --modules B,C --force`.
   Nodes still on the old key are disconnected.

**Hub key:**

1. Hub: `scripts/tls-rotate-server-cert.sh --identity M17-HUB` (the old pair
   is kept as `server.*.<timestamp>.bak`), then `make restart`.
2. Send the new `server.crt` and fingerprint to every field operator.
3. Each field operator reruns `tls-add-hub.sh` with the new cert and restarts
   their nodes. Until then those nodes can't connect, so plan it with them.

## Doing it with plain openssl

OpenSSL 1.1.1 or newer.

```bash
# Key and self-signed cert, 10 years, CN = callsign (M17-HUB for a hub)
openssl req -x509 -newkey ed25519 -nodes -days 3650 \
    -subj "/CN=W5ABC" -addext "subjectAltName=DNS:W5ABC" \
    -keyout client.key -out client.crt
chmod 0600 client.key

# Fingerprint (SPKI SHA-256, base64), the same value the scripts print
openssl x509 -in client.crt -pubkey -noout \
  | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64

# Check a cert you received: name and key type
openssl x509 -in client.crt -noout -subject
openssl x509 -in client.crt -noout -text | grep 'Public Key Algorithm'   # ED25519
```

Then put the files where the layout above says and write the
`mrefd.interlink` lines shown under hub and field setup. A `key:` line's
callsign must equal the certificate's CN, or mrefd skips it.

## Future: CA-signed certificates

Not implemented. For large deployments (hundreds of operators), a hub could
trust one CA certificate instead of registering each operator's key. The cost
is a very valuable CA key and harder revocation. If it is built, it will be
an extra acceptance path next to per-operator registration, not a
replacement.
