# TLS-Authenticated Dynamic Interlink for MREFD

**Status:** implemented
**Author:** Gregg Wonderly (W5GGW)
**Implementation:** greggwon/mrefd fork, branch `tls-interlink` (the `mrefd/` submodule here); PR to n7tae/mrefd later
**Target spec:** M17 Foundation interlink protocol (future)

This document is the protocol design as built: the wire format, the trust
model, and how the mrefd side behaves. It is not an operator guide. How to
set up a hub or a field node lives in [`README.md`](../README.md) (TLS
interlink, ports, configuration) and [`deploy/CERTS.md`](../deploy/CERTS.md)
(keys, certificates, revocation, rotation). Choosing between UDP and TLS
interlinks is covered in
[`deploy/INTERLINK-CHOICES.md`](../deploy/INTERLINK-CHOICES.md).

The implementation has been tested end to end in containers: voice and data
both ways, roaming (a node reconnecting from a new address; the newest
connection wins), silent-drop detection via TCP keepalive, clean shutdown,
rejection of unregistered keys, live key add / module change / revoke, and
simulated slow WAN links.

---

## 1. Problem statement

The upstream `mrefd` interlink protocol assumes that every peer is reachable
at a literal IPv4/IPv6 address configured in `mrefd.interlink`. This assumption
breaks for two important deployment shapes:

1. **Field / event-deployed reflectors** whose public IP changes every venue
   (Starlink, LTE modem, hotel Wi-Fi, borrowed uplinks) — the home reflector
   cannot pre-declare a fixed address to peer with.
2. **Private reflector meshes** — e.g. an ARES section that wants its own
   field kits to connect back to a well-known public reflector without
   publishing those kits on Ham-DHT / `dvref.com`.

The UDP interlink parser (`interlink.cpp`) rejects any non-literal address
with `"is not a valid internet address!"`; hostnames are not accepted.
Ham-DHT is upstream's mechanism for dynamic IP discovery, and it publishes
reflector addresses to the wider public network, which is not always
desired. Field nodes in this project run without DHT; whether hubs publish
on Ham-DHT is not settled, and both builds are supported.

**Goal:** allow a field mrefd instance to authenticate itself to a home
(hub) mrefd instance using a public/private keypair, causing the hub to
install a peer entry using the source address of the incoming TLS session —
without either side pre-declaring the field node's IP, and without
publishing the field reflector to Ham-DHT.

---

## 2. Design decisions

Ordered roughly from most to least foundational.

### 2.1 Transport

- **TCP with TLS (1.2 minimum), on the M17 port (default 17000).** Same port
  number as the UDP M17 protocol; different transport. Both listeners
  coexist. `MREFD_TLS_PORT` can move the TLS listener.
- **Per-peer choice**, not a global mode. A `key:` clause (hub side) or a
  `tls:` clause (field side) on a `mrefd.interlink` line marks that peer as
  TLS/TCP. Lines without them stay legacy UDP. Mixed peer sets on one
  reflector are supported.
- **No auth fallback.** A peer either speaks the TLS-auth mode or it is
  incompatible; the mismatch is a config error, not a graceful degradation.

### 2.2 Identity and cryptographic model

- **The key decides who a peer is.** Each operator holds **one**
  certificate whose Subject CN is their bare callsign (`W5GGW`). Every node
  that operator runs presents that same certificate. The hub looks up the
  presented key by its SPKI SHA-256 fingerprint; nothing the peer *says* can
  change which callsign it is.
- **The node chooses its module.** On each connection the node asserts the
  single module it is linking, the same way a radio picks a module when it
  connects to a reflector. The hub names the node `<CN>-<module>`
  (`W5GGW-B`, `W5GGW-C`, ...), so one operator runs several field boxes at
  once, one per module, with one certificate. The hub's registration lists
  which modules that key may assert.
- **Credentials:** self-signed X.509 certificates with **Ed25519** keys, for
  both the hub and operators. No CA.
- **Trust model:** the field node pins the hub's certificate file as its
  only trust anchor (no hostname check; the CN is the hub's callsign, not its
  DNS name). The hub requires a client certificate in the handshake but does
  not validate a chain; it accepts the connection only if the certificate's
  SPKI fingerprint matches a registered certificate. BIRTH must then name
  that key's callsign plus one permitted module, signed by the same key.
- **Certificate distribution:** out-of-band, with the fingerprint checked by
  phone or email. No TOFU; no automatic trust bootstrap.

### 2.3 Enrollment / key registry

- **No web UI.** Enrollment is a config-file operation, once per operator
  (not per node). The hub keeps the operator's certificate under
  `tls/peers/` and a `CALLSIGN MODULES key:<path>` line in
  `mrefd.interlink`; each node's own `mrefd.interlink` names the hub and the
  one module that node asserts. The `scripts/tls-*.sh` tools write both
  (§7).
- **Hub side hot-reloads** `mrefd.interlink` within seconds, no restart:
  adding the first key starts the TLS listener; changing a key's modules
  disconnects nodes on removed modules; removing a key disconnects all its
  nodes immediately and refuses them from then on.
- **Field side** `tls:` lines take effect when the node restarts.

### 2.4 Connection lifecycle

- **Every reconnect is a fresh birth event.** No session state survives a
  TCP disconnect.
- **Newest connection wins.** If a node (`W5GGW-B`) connects while an older
  session for the same name is still open — typically a roaming node whose
  old path hasn't timed out — the older session is aborted.
- **Liveness is TCP keepalive**, not application PINGs: probe after 60 s
  idle, every 30 s, give up after 8 unanswered probes (about 5 minutes).
  Tunable with `MREFD_TLS_KEEPALIVE`; `MREFD_TLS_USER_TIMEOUT` optionally
  bounds how long unacknowledged data may sit (default off).
- **No connect timeout.** The kernel's SYN retries run their full course so
  slow or lossy links still connect.
- **Retry with backoff** on the field side: 2 s, doubling to a 60 s cap,
  reset after a successful link.
- **Clean shutdown:** on stop, each live session gets a DISCONNECT frame and
  up to about 2 s to flush.
- **Bad networks are bad networks.** TCP semantics are accepted as-is; a
  truncated trailing frame at EOF is discarded.

### 2.5 Threat model

- Public network with hostile actors.
- Server authentication is by the pinned hub certificate; client
  authentication is by the registered key plus the signed BIRTH.
- **DDoS is out of scope.** The hub's operator handles it with firewall /
  rate limiting.
- **Auth-attempt abuse** is out of scope in the protocol. The hub logs each
  refusal with the source address ("unregistered key ... from <addr>"), which
  a fail2ban-style watcher can act on.
- **DNS or routing attacks** on the hub's address are accepted risks;
  certificate pinning defeats DNS-level MITM.

### 2.6 Scope

- **MREFD first.** URFD may adopt the same mechanism later.
- **Reflector-to-reflector only.** Client (hot-spot / radio) connections to
  the reflector are unchanged and use the existing M17 protocol on UDP.

---

## 3. Wire format

### 3.1 Frame header

Every message on the TLS session is framed with a 32-bit big-endian header
followed by the payload (`framing.h`):

```
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    version    |reserved|              length (20 bits)        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
~                    payload  (length bytes)                    ~
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **version (8 bits):** `0x01`.
- **reserved (4 bits, high nibble of byte 1):** zero on transmit. A
  receiver that sees non-zero reserved bits treats the frame as malformed
  and ends the session.
- **length (20 bits):** payload length in bytes, max 1,048,575.

A frame with a different version ends the session ("mismatched mrefd
versions?" in the log). No REJECT is sent for this; it is a framing error.

### 3.2 Message types

The first byte of `payload` is the message type.

| Type | Name        | Direction   | Description                                    |
|------|-------------|-------------|------------------------------------------------|
| 0x01 | BIRTH       | field→hub   | Signed hello naming the node and its module    |
| 0x02 | ACCEPT      | hub→field   | Birth accepted, peer entry installed           |
| 0x03 | REJECT      | hub→field   | Birth rejected, with a reason code             |
| 0x10 | PING        | either      | Answered with PONG; mrefd itself doesn't send it |
| 0x11 | PONG        | either      | Echo of a PING payload                         |
| 0x20 | M17_STREAM  | either      | Wrapped M17 stream-mode packet (voice)         |
| 0x21 | M17_PACKET  | either      | Wrapped M17 packet-mode packet (data)          |
| 0x7F | DISCONNECT  | either      | Graceful shutdown notice                       |

Unknown types are logged and ignored.

### 3.3 BIRTH payload

`birth.h`:

```
+-------------+---------------------------------------------------+
| msg_type    | 0x01                                     (1 byte) |
+-------------+---------------------------------------------------+
| id_len      | identity length in bytes (max 32)        (1 byte) |
+-------------+---------------------------------------------------+
| identity    | ASCII "<cert CN>-<module>", e.g. "W5GGW-B"        |
+-------------+---------------------------------------------------+
| ts_ms       | Unix time in milliseconds         (8 bytes, BE)   |
+-------------+---------------------------------------------------+
| nonce       | 32 bytes of random data                           |
+-------------+---------------------------------------------------+
| sig_len     | signature length, 64 for Ed25519         (1 byte) |
+-------------+---------------------------------------------------+
| signature   | Ed25519 over identity || ts_ms || nonce           |
+-------------+---------------------------------------------------+
| mod_len     | modules string length (max 26)           (1 byte) |
+-------------+---------------------------------------------------+
| modules     | ASCII; the one module asserted, e.g. "B"          |
+-------------+---------------------------------------------------+
```

The signature covers `identity || ts_ms || nonce`. `modules` is not signed
separately, but the hub requires it to equal the module in the (signed)
identity. The nonce makes every signature unique; the timestamp must be
within `MREFD_TLS_TIMESTAMP_SKEW` (default 300 s) of the hub's clock, so
both ends need NTP.

The hub checks, in order (`tlsserver.cpp`):

1. TLS handshake with a client certificate (required).
2. Read and parse BIRTH (read before judging, so a REJECT is delivered
   instead of a reset).
3. Look up the certificate's SPKI fingerprint in the registry.
4. Identity must be `<registered callsign>-<one letter A-Z>`.
5. Signature and timestamp, against the registered certificate.
6. `modules` must be exactly that letter, and the letter must be in the
   registration's module list.

Then it sends ACCEPT.

### 3.4 ACCEPT / REJECT

`ACCEPT` is `msg_type` only. `REJECT` is `msg_type` plus a 1-byte reason
code; there is no diagnostic string. The field node turns the code into a
log line and the dashboard's LastError.

| Code | Hub sends it when                                              |
|------|----------------------------------------------------------------|
| 0x01 | Key not registered, no usable client cert, or identity doesn't match the key's callsign |
| 0x02 | Signature didn't verify                                        |
| 0x03 | Timestamp outside the skew window (check NTP)                  |
| 0x04 | Module not allowed for this key (or more than one asserted)    |
| 0x05 | Reserved for version mismatch; not sent (version is checked at the framing layer) |
| 0xFF | BIRTH didn't parse, or other verify failure                    |

### 3.5 PING / PONG

A PONG echoes the PING payload with the type byte changed. mrefd answers
PINGs but does not send them; dead links are found by TCP keepalive
(§2.4).

### 3.6 M17_STREAM / M17_PACKET

The payload after the type byte is the M17 packet exactly as it would be
sent over UDP (`"M17 "` stream frames, `"M17P"` packet-mode frames, at most
`MAX_PACKET_SIZE` = 860 bytes). The sender picks 0x20 or 0x21 from that
magic. The receiver feeds the packet into the same dispatch as a UDP
receive, with the TLS peer's address as the source.

### 3.7 DISCONNECT

`msg_type` only. Sent to every live session when mrefd stops. The receiver
ends the session and logs "peer sent DISCONNECT".

---

## 4. Configuration

### 4.1 `mrefd.interlink` syntax

A line containing a `key:`, `tls:` or `servercert:` token is a TLS line.
Modules may be written `B,C`, `BC` or `"b c"`; the scripts write `B,C`.

Legacy forms (unchanged):

```
# Legacy IP+port:
M17-URF 45.32.11.22 17000 B,C,D

# Legacy pre-1.0 peer:
M17-QQQL 44.45.45.100 ABC

# DHT form (DHT builds only):
M17-QQQ ABC
```

TLS forms, as the scripts write them:

```
# Hub: register operator W5ABC's key. Nodes holding it may assert B or C
# and appear as W5ABC-B / W5ABC-C. The callsign must equal the cert's CN,
# or the line is skipped with a log message.
W5ABC      B,C      key:/etc/mrefd/tls/peers/W5ABC.pub.pem

# Field node: dial the hub and assert ONE module. The hub's certificate is
# pinned by pointing at a local copy.
M17-HUB    B   tls:hub.example.org:17000  servercert:/etc/mrefd/tls/hubs/M17-HUB.crt
```

Rules enforced by the parser (`interlinks.cpp`):

- A line may not mix `key:` and `tls:`.
- A `tls:` line must assert exactly one module, and needs `servercert:`.
- `tls:` takes `host:port` or `host` (port 17000). IPv6 literals are not
  supported; use a DNS name.
- A `key:` line's name must be a bare callsign (no `-module`).

The field node's own certificate and key are not on the line; they are the
reflector-wide client credentials (§4.2). The node's name at the hub is
that certificate's CN plus the line's module.

### 4.2 Environment variables

`mrefd.cfg` has no TLS settings. TLS is configured by the `mrefd.interlink`
lines above plus these optional environment variables:

| Variable                    | Default                                     |
|-----------------------------|---------------------------------------------|
| `MREFD_TLS_SERVER_CERT`     | `/etc/mrefd/tls/server.crt` if present (hub)  |
| `MREFD_TLS_SERVER_KEY`      | `/etc/mrefd/tls/server.key` if present      |
| `MREFD_TLS_CLIENT_CERT`     | `/etc/mrefd/tls/client.crt` if present (field) |
| `MREFD_TLS_CLIENT_KEY`      | `/etc/mrefd/tls/client.key` if present      |
| `MREFD_TLS_PORT`            | `MREFD_PORT` (17000)                        |
| `MREFD_TLS_BIND_ADDR`       | `MREFD_IPV6_BIND`, else `0.0.0.0`           |
| `MREFD_TLS_TIMESTAMP_SKEW`  | 300 (seconds)                               |
| `MREFD_TLS_MAX_AUDIO_MS`    | 200 (voice older than this is dropped)      |
| `MREFD_TLS_DATA_QUEUE_KB`   | 1024 (cap on queued packet-mode data)       |
| `MREFD_TLS_KEEPALIVE`       | `60,30,8` (idle s, interval s, probes), or `off` |
| `MREFD_TLS_USER_TIMEOUT`    | 0 (off)                                     |

The cert/key defaults come from the container entrypoint, which uses the
files in `config/tls/` when the variables are unset. If a key exists but
the container user (uid 1000) can't read it, the container stops and prints
the `chown` command to run.

### 4.3 Build

TLS is always compiled in. There is no `TLS=true` build flag; the mrefd
Makefile always links `-lssl -lcrypto`. Ham-DHT remains a separate build
choice (`MREFD_BUILD_DHT`, default false).

---

## 5. `mrefd` source changes (as built)

### 5.1 New files

- **`framing.h/.cpp`** — frame header serialize/parse, message types.
- **`birth.h/.cpp`** — BIRTH build/parse/verify (Ed25519 via OpenSSL),
  nonce generation, certificate CN and SPKI fingerprint helpers, identity
  parsing.
- **`tlssession.h/.cpp`** — one TLS session: blocking framed I/O for the
  handshake and BIRTH, then the non-blocking I/O loop (§6).
- **`tlsserver.h/.cpp`** — TCP listener, `SSL_accept`, BIRTH checks
  (§3.3), one thread per accepted connection.
- **`tlsclient.h/.cpp`** — outbound TCP connect (every `getaddrinfo`
  address in turn, no timeout of its own), `SSL_connect` with the pinned hub
  cert, BIRTH, ACCEPT/REJECT.
- **`tlsinterlinks.h/.cpp`** — orchestration: builds the key registry from
  `mrefd.interlink`, starts the server and one retry thread per `tls:`
  target, hot reload and revocation, routes M17 traffic to and from
  sessions, link status for `mrefd.json`.
- **`tests/tls-selftest.cpp`** — self-test: framing, BIRTH sign/verify/skew, and a loopback handshake.

### 5.2 Modified files

- **`interlinks.cpp/.h`** — `ParseTLSLine` for `key:`, `tls:` and
  `servercert:` lines.
- **`protocol.cpp/.h`** — per-callsign senders so packets for a TLS peer go
  to its session instead of UDP; TLS-received packets go through the normal
  packet dispatch.
- **`reflector.cpp/.h`** — reads the `MREFD_TLS_*` variables, starts and
  stops the TLS layer, adds the `TLS` object to `mrefd.json`.
- **`gatekeeper.cpp`** — calls the TLS reload when `mrefd.interlink`
  changes.
- **`Makefile`** — always links OpenSSL.

---

## 6. Session I/O (as built)

From `tlssession.cpp`. The goal is that voice stays current and data
arrives, on links from LAN speed down to a few kbit/s.

- **One I/O thread per link.** After BIRTH, `RunIO()` switches the socket to
  non-blocking and becomes the only thread touching the `SSL*`. It
  `poll()`s the socket plus a self-pipe. The reflector hands it frames
  through `Send()` / `SendControl()`, which only queue and never block, so a
  slow link can't stall the reflector. An idle link sleeps in `poll()`.
- **Priority: control, then voice, then data.** Control frames (PONG,
  DISCONNECT) are never dropped and go first. Data goes only when no voice
  is waiting.
- **Voice is kept current; data is reliable.** Voice that has waited in
  mrefd's queue longer than `MREFD_TLS_MAX_AUDIO_MS` (default 200 ms, about
  five M17 frames) is dropped, not sent late. Data (packet mode) is never
  dropped for age; only if its queue passes `MREFD_TLS_DATA_QUEUE_KB` are
  the oldest data frames dropped. Network latency by itself never causes
  drops; only a link slower than the voice does.
- **Backlog check.** M17 frames are handed to the socket only when they'll
  get through in time. The loop reads the kernel's outq (`SIOCOUTQ`, unsent
  plus unacknowledged bytes), estimates the ack rate from how fast that
  drains, and takes RTT from `TCP_INFO`. Queueing shows up as RTT above the
  path's base RTT (a windowed minimum over the last 10–20 s, so it follows a
  path change such as a Starlink handoff). If queueing exceeds the voice
  budget, or bytes in flight exceed about twice what the link clears in a
  base RTT plus the budget, frames stay in mrefd's queue, where stale voice
  can still be dropped. A few frames (512 bytes) may always be in flight.
  `TCP_NOTSENT_LOWAT` keeps the kernel's unsent backlog to a few frames and
  `TCP_NODELAY` is set.
- **Small batching.** When several frames are waiting they go in one TLS
  record, up to about one TCP segment (1200 bytes), but never more than the
  link can clear within the budget; on 8 kbit/s that is a frame or two.
- **TCP keepalive and no connect timeout** (§2.4).
- **Voice delay trend.** Each sent voice frame's lateness (time queued in
  mrefd plus network queueing above base RTT) is tracked per transmission.
  Each second keeps its least-late frame; if that floor rises for two
  seconds running, or creeps up by three frames' worth (120 ms) and keeps
  rising, the trend is "growing" and the log says the link is falling behind
  (once per transmission). A steady delay is fine. `mrefd.json` reports
  `VoiceTrend` as idle / steady / growing, plus `VoiceLateMs`,
  `VoiceQueue`, `VoiceQueuePeak`, `VoiceDropped` and `VoiceDroppedRecent`.
  While stale voice is being dropped, the log says so every 10 s and
  suggests using data (packet mode) on that link.

Voice over the TLS link needs about 31 kbit/s each way (each 61-byte M17
frame is about 150 bytes with TLS/TCP/IP overhead). Below that, voice
breaks up while data still gets through.

---

## 7. Key management scripts

The scripts live in `scripts/` and are also installed in the image as
`tls-genkey`, `tls-add-peer`, `tls-add-hub`, `tls-remove-peer`,
`tls-list-peers`, `tls-rotate-server-cert` and `tls-verify`. They share
`tls-common.sh`: every one but `tls-verify` takes `--config <dir>` (default:
`$M17_CONFIG_DIR`, else the repo's `config/`, else `/etc/mrefd` in the
image), accepts lowercase, and finds Homebrew `openssl@3` on macOS. Usage
and examples are in [`deploy/CERTS.md`](../deploy/CERTS.md).

| Script                    | Side  | What it does |
|---------------------------|-------|--------------|
| `tls-genkey.sh`           | both  | Makes an Ed25519 key and self-signed cert: `tls/client.*` (field, `--identity` = operator's bare callsign) or `tls/server.*` (`--role hub`, `--identity` = reflector callsign). Prints the SPKI fingerprint. `--force` to replace. |
| `tls-add-peer.sh`         | hub   | Copies an operator's cert to `tls/peers/<CALL>.pub.pem` and writes the `key:` line. CN taken from the cert. Refuses a different key for an existing callsign without `--force`, and a key already registered under another name. Rerun with new `--modules` to change modules. Live. |
| `tls-remove-peer.sh`      | hub   | Removes the operator's line and cert (`--keep-cert` to keep the file). mrefd disconnects all their nodes within seconds. |
| `tls-add-hub.sh`          | field | Copies the hub cert to `tls/hubs/<M17-XXX>.crt` and writes the `tls:` line for one module. `--remove` to drop a hub. Restart the node afterwards. |
| `tls-list-peers.sh`       | both  | Registered keys with modules, fingerprint and connected nodes (hub); hubs with link state and last error (field). Reads `mrefd.json`, via `docker exec` if needed. `--json` available. |
| `tls-rotate-server-cert.sh` | hub | Keeps the old pair as `*.<timestamp>.bak` and makes a new hub key. Restart the hub; every field operator reruns `tls-add-hub.sh` with the new cert. |
| `tls-verify.sh`           | field | Checks the hub is reachable on TCP and does a TLS handshake; prints the hub cert's CN and fingerprint and compares it with `--expect-fingerprint`. Whether the hub accepts *your* key is decided after the handshake; the node's log and dashboard report that. |

There is no admin socket and no iptables step: revocation works through hot
reload (§2.3).

---

## 8. Operations

Setup, revocation and rotation procedures are in
[`deploy/CERTS.md`](../deploy/CERTS.md). What to watch:

- **Logs:** `link UP` / `link DOWN ... after <duration>: <reason> (frames
  in N, out N, stale voice dropped N)`. Reasons are plain English: keepalive
  timeout, peer reset, "peer sent DISCONNECT", DNS failure, refused, hub
  rejected us (key not registered / module not allowed / clock skew).
  Connect attempts are logged for the first three, then every 10th, with how
  long the link has been down.
- **`mrefd.json`:** a `TLS` object with `Listening`, `Registrations` and
  `Links[]` (State connected/connecting/retrying/disconnected, LastError,
  FramesIn/Out and the voice fields in §6).
- **Dashboard:** a "TLS Links" page and a badge on every page: green link
  up, yellow voice falling behind (delay growing), red stale voice being
  dropped or link down, grey waiting for nodes.

---

## 9. Phasing

**Phase 0 — Design.** Done (this document, now updated to the build).

**Phase 1 — Reference implementation in the `greggwon/mrefd` fork.** Done.
TLS is always compiled in; UDP interlink behavior is unchanged.

**Phase 2 — Container tooling and scripts.** Done: the §7 scripts (also in
the image), entrypoint key discovery, `config/tls` mounts in both compose
files, dashboard TLS page and badge, README and `deploy/CERTS.md`.

**Phase 3 — PR to `n7tae/mrefd`.** Not started. Waiting for production time
(target: one full ARES exercise cycle). Expect iteration on wire format and
config syntax.

**Phase 4 — M17 Foundation spec proposal.** Not started.

**Phase 5 — URFD implementation.** Not started.

---

## 10. Open questions

1. **Key format on disk.** Decided: PEM certificates (`.crt`, `.pub.pem`).
2. **Multiple sessions for one node name.** Decided: the newest connection
   wins and the older one is aborted with a log line. Different modules on
   one key are separate nodes and run side by side.
3. **Admin socket.** Dropped: not built and not needed, since hot reload
   disconnects revoked keys and removed modules.
4. **Cross-arch cert compatibility.** Still worth checking on `linux/arm/v7`
   specifically.
5. **Ham-DHT on hubs.** Open. Field nodes run without DHT. Whether hubs also
   publish on Ham-DHT is undecided; both builds work.
6. **Field-side hot reload.** Adding or changing a field node's `tls:` line
   currently needs a restart of that node.
7. **IPv6 literals in `tls:` lines.** Not supported yet; use a DNS name.
8. **CA-signed operator certs.** A possible future acceptance path for large
   deployments; see `deploy/CERTS.md`.

---

## 11. References

- `mrefd/framing.h`, `mrefd/birth.h` — wire format.
- `mrefd/tlsserver.cpp`, `mrefd/tlsclient.cpp` — handshake and BIRTH checks.
- `mrefd/tlssession.cpp` — session I/O (§6).
- `mrefd/tlsinterlinks.cpp` — registry, reload, retry, routing, status.
- `mrefd/interlinks.cpp` — interlink file parser, `ParseTLSLine`.
- `mrefd/interlink.cpp` — UDP peer address check (literal addresses only).
- M17 Foundation protocol docs — https://m17project.org/
- Ed25519 signing scheme — RFC 8032.
- TLS raw public keys (alternative to self-signed certs) — RFC 7250.
