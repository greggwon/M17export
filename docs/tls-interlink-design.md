# TLS-Authenticated Dynamic Interlink for MREFD

**Status:** design draft
**Author:** Gregg Wonderly (W5GGW)
**Target implementation:** greggwon/mrefd fork, then PR to n7tae/mrefd
**Target spec:** M17 Foundation interlink protocol (future)

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

Verified in source (`interlink.cpp:45`): the interlink parser rejects any
non-literal address with `"is not a valid internet address!"`. Hostnames are
not accepted. Ham-DHT is the only currently-supported mechanism for dynamic
IP discovery, and it publishes reflector addresses to the wider public
network, which is not always desired.

**Goal:** allow a field mrefd instance to authenticate itself to a home
mrefd instance using a public/private keypair, causing the home to install
a peer entry using the source address of the incoming TLS session — without
either side pre-declaring an IP, and without publishing the field reflector
to Ham-DHT.

---

## 2. Design decisions

Ordered roughly from most to least foundational.

### 2.1 Transport

- **TCP on port 17000** with TLS. Same port number as the existing UDP
  interlink; different transport protocol. Both listeners coexist.
- **Per-peer choice**, not global mode. Presence of a `key:<file>` clause on
  a `mrefd.interlink` entry marks that peer as TLS/TCP. Absence keeps it as
  legacy UDP. Mixed peer sets on a single reflector are supported.
- **No auth fallback.** A peer either supports the TLS-auth mode or it is
  incompatible; the mismatch is a config error, not a graceful degradation.

### 2.2 Identity and cryptographic model

- **The key decides who a peer is.** Each operator holds **one**
  certificate whose Subject CN is their bare callsign (`W5GGW`). Every node
  that operator runs presents that same certificate. The hub looks up the
  presented key by its SPKI fingerprint; nothing the peer *says* can change
  which callsign it is.
- **The node chooses its module.** On each connection the node asserts the
  single module it is linking, the same way a radio picks a module when it
  connects to a reflector. The hub names the node `<CN>-<module>`
  (`W5GGW-B`, `W5GGW-C`, ...), so one operator runs several field boxes at
  once, one per module, with one certificate. The hub's registration lists
  which modules that key may assert.
- **Field credential:** self-signed X.509 certificate with an **Ed25519**
  keypair. Small, universally supported by modern TLS libraries, no CA
  infrastructure required.
- **Trust model:** the field trusts the server's cert (obtained
  out-of-band, pinned). The server requires a client certificate in the
  TLS handshake and accepts it only if its SPKI fingerprint matches a
  registered keyfile; BIRTH must then name that key's callsign plus one
  permitted module, signed by the same key.
- **Server cert distribution:** out-of-band — a published cert on the
  server operator's website, on DVREF, or handed over directly. No TOFU;
  no automatic trust bootstrap.

### 2.3 Enrollment / key registry

- **No web UI.** Enrollment is a config-file operation, once per
  operator (not per node):
  1. Operator generates one keypair and cert, CN = their callsign.
  2. Operator sends the public cert to the home operator (email, PR to a
     config repo, etc.) and copies cert + key to each of their nodes.
  3. Home operator drops the cert file on the server and adds a
     `CALLSIGN MODULES key:<path>` line to `mrefd.interlink`, where
     MODULES are the modules that operator's nodes may assert.
  4. Each node's own `mrefd.interlink` names the hub and the one module
     that node asserts.
- `mrefd` hot-reloads `mrefd.interlink` today; the extension retains that
  behavior for the new field.
- Same behavior for revocation: remove line + delete keyfile, which
  revokes every node using that key. To retire one node but keep the
  others, drop its module from the registration's MODULES.

### 2.4 Connection lifecycle

- **Every reconnect is a fresh birth event.** No persistent session state
  across TCP disconnects.
- **PING/PONG keepalive** keeps the peer entry alive. Missed keepalive drops
  the peer entry; the field's next reconnect will re-birth.
- **Retry with backoff** on the field side when the home is unreachable.
- **Bad networks are bad networks.** No heroic recovery logic. TCP semantics
  are accepted as-is: what is written is delivered whole or truncated at
  EOF; truncated trailing frames are discarded.
- **Live-session cutoff on revocation** is out of band via `iptables` block
  on the source IP. A CLI tool automates this (see §7).

### 2.5 Threat model

- Public network with hostile actors.
- One-way authentication is sufficient: no need to defend the field against
  a hostile server pretending to be the home reflector at the level of a
  full mutual auth. Distributing the server cert out-of-band gives adequate
  server authentication.
- **DDoS is out of scope.** Public server admin is responsible via firewall
  / rate limiting / fail2ban.
- **Auth-attempt exploits** are also out of scope in the protocol; a
  fail2ban-style script watching auth failures and adding iptables blocks
  is the deployment answer.
- **DNS or routing attacks** on the server's advertised address are
  accepted risks; server cert pinning defeats DNS-level MITM.

### 2.6 Scope

- **MREFD first.** URFD may adopt the same mechanism later if the maintainer
  is interested; not a blocker for landing the MREFD implementation.
- **Reflector-to-reflector only.** Client (hot-spot / radio) connections to
  the reflector are unchanged and continue to use existing M17 client
  protocols on UDP.

---

## 3. Wire format

### 3.1 Frame header

Every message on the TLS session is framed with a 32-bit big-endian header
followed by the payload:

```
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    version    |  reserved   |             length              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
~                    payload  (length bytes)                    ~
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **version (8 bits):** protocol version. `0x01` in this draft.
- **reserved (4 bits):** MUST be zero on transmit; ignored on receive.
- **length (20 bits):** payload length in bytes. Max frame ≈ 1 MB — well
  above any M17 packet-mode payload (largest existing M17 protocol packet is
  ~800 bytes; length field has room for expansion).

Rejecting a frame with a non-matching version terminates the TLS session.

### 3.2 Message types

The first byte of `payload` is a message type identifier. Following bytes
are message-type specific.

| Type | Name        | Direction   | Description                                    |
|------|-------------|-------------|------------------------------------------------|
| 0x01 | BIRTH       | field→home  | Authenticated hello with signed identity       |
| 0x02 | ACCEPT      | home→field  | Birth accepted, peer entry installed           |
| 0x03 | REJECT      | home→field  | Birth rejected (bad sig, unknown callsign, …)  |
| 0x10 | PING        | either      | Keepalive request                              |
| 0x11 | PONG        | either      | Keepalive response                             |
| 0x20 | M17_STREAM  | either      | Wrapped M17 Stream Mode packet                 |
| 0x21 | M17_PACKET  | either      | Wrapped M17 Packet Mode packet                 |
| 0x7F | DISCONNECT  | either      | Graceful shutdown notice                       |

### 3.3 BIRTH payload

```
+----------------+------------------------------------------------+
| msg_type=0x01  | (1 byte)                                       |
+----------------+------------------------------------------------+
| id_len         | length of identity string in bytes (1 byte)    |
+----------------+------------------------------------------------+
| identity       | ASCII "<cert CN>-<module>", e.g. "W5GGW-B"     |
+----------------+------------------------------------------------+
| timestamp_ms   | 64-bit big-endian Unix time in milliseconds    |
+----------------+------------------------------------------------+
| nonce          | 32 bytes of cryptographically random data      |
+----------------+------------------------------------------------+
| sig_len        | length of signature (1 byte, Ed25519 = 64)     |
+----------------+------------------------------------------------+
| signature      | Ed25519 signature over identity||timestamp||nonce|
+----------------+------------------------------------------------+
| modules        | ASCII string listing requested shared modules  |
+----------------+------------------------------------------------+
```

Signature covers `identity || timestamp_ms || nonce` (concatenated bytes,
big-endian for the timestamp). The nonce ensures every signature is unique
regardless of clock resolution; the timestamp gives freshness that the home
can check against a configurable skew window (default ±5 minutes) to defeat
long-window replay.

### 3.4 ACCEPT / REJECT

`ACCEPT` payload is `msg_type` only. `REJECT` payload adds a 1-byte reason
code and a variable-length ASCII diagnostic:

| Code | Meaning                                    |
|------|--------------------------------------------|
| 0x01 | Unknown identity                            |
| 0x02 | Signature verification failed              |
| 0x03 | Timestamp outside skew window (stale/future)|
| 0x04 | Requested modules not permitted for this identity |
| 0x05 | Version not supported                      |
| 0xFF | Other (see diagnostic string)              |

### 3.5 PING / PONG

Both carry a 32-bit big-endian sequence number in the payload. Sender picks
sequence values; receiver echoes in `PONG`. Default cadence: `PING` every
10 seconds, disconnect after two missed `PONG`s.

### 3.6 M17_STREAM / M17_PACKET

Payload is the raw existing mrefd interlink packet body (unchanged from the
current UDP interlink protocol). This preserves all existing M17 semantics —
callsigns, module addressing, encryption flags — and lets most of the
existing packet-handling code paths in mrefd be reused unmodified.

---

## 4. Configuration file changes

### 4.1 Extended `mrefd.interlink` syntax

New optional field: `key:<filepath>` in any position among the whitespace-
separated tokens. Its presence marks the peer as TLS/TCP.

Legacy forms (unchanged):

```
# DHT-based (both sides on Ham-DHT):
M17-QQQ ABC

# Legacy IP+port:
M17-URF 45.32.11.22 17000 BCD

# Legacy pre-1.0 peer:
M17-QQQL 44.45.45.100 ABC
```

New TLS forms:

```
# Home-side: register operator W5GGW's key. Any node presenting it may
# connect asserting B, C or D, and appears as W5GGW-B / W5GGW-C / W5GGW-D.
# The callsign must equal the cert's CN; no IP or port needed.
W5GGW BCD key:/etc/mrefd/tls/peers/W5GGW.pub.pem

# Field-side: dial the hub and assert ONE module (here B). The hub's
# server cert is pinned by pointing at a local copy.
M17-HOM B tls:home.example.org:17000 servercert:/etc/mrefd/tls/home.pem
```

The field's own cert and private key are declared once at the reflector
level (see §4.2), not per-peer: the node's callsign comes from that cert,
and each `tls:` line adds the module asserted on that link.

### 4.2 `mrefd.cfg` additions

```
# ---- TLS interlink ---------------------------------------------------------
# Enable the TLS/TCP listener on Port. Required for any home-side TLS peer.
TLSEnabled = true

# Server certificate and key (this reflector's identity when accepting
# incoming TLS peers). Required when TLSEnabled = true.
TLSServerCert = /etc/mrefd/tls/server.crt
TLSServerKey  = /etc/mrefd/tls/server.key

# Client certificate and key (this reflector's identity when initiating
# outbound TLS peers). Required if any interlink entry uses `tls:` form.
TLSClientCert = /etc/mrefd/tls/client.crt
TLSClientKey  = /etc/mrefd/tls/client.key

# Allowed clock-skew window for BIRTH timestamps, in seconds. Default 300.
TLSTimestampSkew = 300
```

### 4.3 `mrefd.mk` additions

```
# Compile in TLS interlink support. Requires libssl-dev (or equivalent).
TLS = true
```

---

## 5. `mrefd` source changes

Grouped by file. Rough scope; detailed diffs to follow in the implementation
PR.

### 5.1 New files

- **`tlssession.h/.cpp`** — Wraps a single TLS session (`SSL*` handle plus
  socket, buffered read state, framing state machine). Owned either by
  `CTLSServer` (accepted session) or `CTLSClient` (outbound session).
- **`tlsserver.h/.cpp`** — TCP listener + `SSL_accept` loop. Maintains a
  map of active `TLSSession` instances keyed by identity.
- **`tlsclient.h/.cpp`** — Outbound TCP + `SSL_connect` for `tls:` peers.
  Handles reconnect/backoff.
- **`framing.h/.cpp`** — Frame header parse/serialize; message-type dispatch
  table.
- **`birth.h/.cpp`** — BIRTH message construction (client) and verification
  (server). Ed25519 signature via libssl / libsodium.
- **`certstore.h/.cpp`** — Loads and caches the peer keyfiles referenced
  from `mrefd.interlink` entries. Watches for file change / removal so a
  keyfile deletion triggers a live-session tear-down.

### 5.2 Modified files

- **`interlinks.cpp/.h`** — Extend `LoadFromFile` to parse `key:`, `tls:`,
  and `servercert:` tokens. Add new `Emplace` variants that carry those
  fields. Route TLS-form entries to `CTLSServer` (home side) or
  `CTLSClient` (field side) instead of the UDP path.
- **`interlink.cpp/.h`** — Extend `CInterlink` with a transport enum
  (`UDP` / `TLS`) and store the TLS credentials/paths where relevant.
- **`protocol.cpp/.h`** — Route packets received via `TLSSession` through
  the same processing path as UDP packets. The wrapped `M17_STREAM` /
  `M17_PACKET` payload is byte-for-byte identical to today's UDP packet
  body, so most handler code is unchanged.
- **`configure.cpp/.h`** — Add parsing for `TLSEnabled`, `TLSServerCert`,
  `TLSServerKey`, `TLSClientCert`, `TLSClientKey`, `TLSTimestampSkew`.
- **`main.cpp`** — Start `CTLSServer` if `TLSEnabled` is true and any
  interlink entry is TLS-form.
- **`Makefile`** — Add `TLS` build flag; link `-lssl -lcrypto` when set.
- **`example.mk`** — Add `TLS = true` to the template.
- **`example.cfg`** — Add the TLS configuration block from §4.2.
- **`README.md`** — Document the new mode.

### 5.3 Estimated effort

Two moderate weeks of one focused engineer for a working proof of concept
in the fork; another one to two weeks for polish, tests, and documentation
before opening the PR to upstream.

---

## 6. Container / tooling changes in this repo

### 6.1 `.env.example` additions

```
# ---- TLS interlink ----
# Enable the TCP/TLS listener alongside the UDP interlink.
MREFD_TLS_ENABLED=false

# Reflector's own TLS server credentials (home-side accepting).
MREFD_TLS_SERVER_CERT=/etc/mrefd/tls/server.crt
MREFD_TLS_SERVER_KEY=/etc/mrefd/tls/server.key

# Reflector's own TLS client credentials (field-side initiating).
MREFD_TLS_CLIENT_CERT=/etc/mrefd/tls/client.crt
MREFD_TLS_CLIENT_KEY=/etc/mrefd/tls/client.key

# Allowed clock-skew window on BIRTH timestamps, in seconds.
MREFD_TLS_TIMESTAMP_SKEW=300
```

### 6.2 Dockerfile changes

- `docker/mrefd/Dockerfile` build stage: add `libssl-dev` to the apt-get
  install list.
- Runtime stage: add `libssl3` to the runtime image.
- Optional: add `openssl` binary to the runtime image so admins can inspect
  certs from inside the container.

### 6.3 Compose changes

- `docker-compose.yml`: publish TCP 17000 in addition to UDP 17000 (host
  mode already exposes both, but the bridge-mode overlay
  `docker-compose.bridge.yml` needs the extra TCP publish added).
- Add a bind mount for `./config/tls/` into `/etc/mrefd/tls/` so
  certificates and peer keyfiles are host-managed.

### 6.4 Wizard (`scripts/init.sh`) additions

Add a "TLS interlink" section:
- Ask whether this instance is a home (server), field (client), or both.
- For home: offer to generate `server.crt` / `server.key` if absent.
- For field: offer to generate `client.crt` / `client.key` if absent.
- For field: prompt for home reflector's public address and cert file path.
- Print the resulting cert fingerprint for enrollment.

### 6.5 Directory layout under `./config/`

```
./config/
├── mrefd.interlink       # extended syntax
├── mrefd.whitelist
├── mrefd.blacklist
└── tls/
    ├── server.crt        # this reflector's server cert (home mode)
    ├── server.key        # (0600, mrefd only)
    ├── client.crt        # this reflector's client cert (field mode)
    ├── client.key        # (0600)
    ├── home.pem          # pinned server cert of upstream (field mode)
    └── peers/            # home-side directory of accepted peer certs
        ├── W5GGW.pub.pem
        ├── W5GGW-C.pub.pem
        └── K7ABC-B.pub.pem
```

---

## 7. CLI tools for key management

A small set of scripts in `scripts/` for common admin tasks. All scripts
assume they run on the host (not inside the container) with normal user
privileges except where noted.

### 7.1 `scripts/tls-genkey.sh`

Generate a fresh Ed25519 keypair and self-signed cert. Usable in either
role (server or client). Prints the fingerprint.

```
scripts/tls-genkey.sh --identity W5GGW \
    --out ./config/tls/client
# writes client.crt and client.key (0600)
# prints SPKI SHA-256 fingerprint for out-of-band sharing
```

### 7.2 `scripts/tls-add-peer.sh`  (home-side)

Register a field's public cert in the local registry and append the
matching line to `mrefd.interlink`.

```
scripts/tls-add-peer.sh --identity W5GGW \
    --cert /path/to/W5GGW.pub.pem \
    --modules BCD
# copies cert to ./config/tls/peers/W5GGW.pub.pem
# appends: "W5GGW BCD key:/etc/mrefd/tls/peers/W5GGW.pub.pem"
# mrefd hot-reloads mrefd.interlink; new peer is immediately accepted
```

Refuses to register a duplicate identity; refuses if the cert file's
fingerprint conflicts with an existing peer's.

### 7.3 `scripts/tls-remove-peer.sh`  (home-side)

Revoke a field. Removes the interlink line, deletes the peer cert, AND
tears down any active session for that identity.

```
scripts/tls-remove-peer.sh --identity W5GGW
```

Steps performed, in order:
1. Delete `./config/tls/peers/W5GGW.pub.pem`.
2. Remove the matching line from `mrefd.interlink`.
   (mrefd's file watcher picks up both changes within seconds.)
3. Send a signal into the mrefd container to close any live session for
   the identity — either via a Unix-domain admin socket (preferred; new
   feature) or as a fallback, look up the peer's currently-recorded
   source IP from the JSON status file and insert an `iptables` REJECT
   rule that kills the TCP session immediately.

### 7.4 `scripts/tls-list-peers.sh`

Print the current peer registry: identity, cert fingerprint, modules,
whether a session is currently connected, and (if so) source IP and
session duration.

### 7.5 `scripts/tls-rotate-server-cert.sh`

Generate a new server keypair, install it, restart the TLS listener
(existing sessions dropped and re-birthed). Prints the new fingerprint
for redistribution.

### 7.6 `scripts/tls-verify.sh`

Diagnostic. Attempts a TLS handshake against a running mrefd TLS listener
(local or remote) with the given client cert, and reports success/failure
of each stage: TCP connect, TLS handshake, server-cert match, BIRTH
exchange, ACCEPT/REJECT reason code. Meant to be the first thing a field
operator runs to diagnose "why can't I connect?"

### 7.7 Admin socket in mrefd

To support §7.3 cleanly, mrefd grows a Unix-domain admin socket (path
configurable, default `/var/run/mrefd/admin.sock`) with a small text
protocol:

```
DISCONNECT <identity>       # close active session, log the reason
STATUS                       # print peer table with connection state
RELOAD                       # explicit re-read of interlink and cert store
```

The socket is 0600 owned by the mrefd user; the CLI scripts `sudo` into
it as needed.

---

## 8. Deployment guide

### 8.1 Public reflector (home)

1. `make init` sets role = home, generates server cert.
2. Publish the server cert fingerprint on your website / DVREF entry.
3. As field operators send their public certs, run
   `scripts/tls-add-peer.sh` for each.
4. `make up` starts the container; both UDP and TCP 17000 are listening.

### 8.2 Field kit

1. `make init` sets role = field, generates client cert.
2. Note the printed identity + fingerprint; send to home operator with
   the modules you want to share.
3. Download the home's server cert (pinned trust).
4. `make up` starts the container. On WAN availability, the field TLS
   client connects out to the home, sends BIRTH, receives ACCEPT, peer
   entry is installed. Interlink traffic flows.

### 8.3 Revoking a field

1. Home operator: `scripts/tls-remove-peer.sh --identity W5GGW`.
2. mrefd hot-reloads config, admin socket closes the live session, cert
   is deleted from disk. Field's future reconnect attempts get REJECT
   reason 0x01 (Unknown identity).

### 8.4 Field key rotation

1. Field: `scripts/tls-genkey.sh --identity <same>` to regenerate.
2. Send the new public cert to home.
3. Home: `scripts/tls-add-peer.sh --identity <same> --cert <new>`
   (replaces the old cert file; hot-reload happens automatically).
4. Field: restart mrefd; new cert takes effect on next connect.

---

## 9. Phasing

**Phase 0 — Design (this document).**
Land it in the `greggwon/M17export` repo as the working spec. Share with
N7TAE early for gross-shape feedback before writing code.

**Phase 1 — Reference implementation in `greggwon/mrefd` fork.**
Land the source changes from §5. Ship a working proof of concept behind
the `TLS = true` build flag. All existing UDP interlink behavior unchanged
when the flag is off. Publish the container repo changes from §6 alongside
so field operators can try it end-to-end.

**Phase 2 — Container tooling and CLI scripts.**
The §7 CLI tools; the wizard integration; documentation refresh in the
top-level `README.md`. Multi-arch image published to a public registry.

**Phase 3 — PR to `n7tae/mrefd`.**
Once the fork has run in production long enough to shake out real bugs
(target: one full ARES exercise cycle), open the PR. Expect design
iteration from N7TAE — the wire format and config syntax are likely to
attract comments.

**Phase 4 — M17 Foundation spec proposal.**
Once N7TAE and any other reflector maintainers are aligned, write up the
handshake and framing as a formal addition to the M17 interlink spec so
URFD and any future reflector can implement compatibly.

**Phase 5 — URFD implementation.**
Contribute the same auth mechanism to URFD's M17 interlink path so a
URFD-hosted talkgroup can be reached from a private field mrefd without
either side hand-configuring IPs.

---

## 10. Open questions

Not blockers for beginning implementation, but worth capturing:

1. **Key format on disk.** Store peer certs as PEM (`-----BEGIN CERTIFICATE-----`)
   for openssl-compatibility, or raw SPKI? PEM is the friendlier default and
   admins can inspect with `openssl x509 -text`. Recommendation: PEM.
2. **Multiple simultaneous sessions per identity.** One certificate may
   back several nodes at once, one per module (`W5GGW-B`, `W5GGW-C`).
   If a second connection arrives asserting a module that is already
   connected for that key, should the older one be terminated (last-write
   wins) or the newer one rejected? Recommendation: last-write wins with a
   log line, matching typical operator expectation after a field
   reconnect from a different network.
3. **Admin socket UX.** The §7.7 socket protocol is intentionally sparse.
   A future iteration could expose it as a JSON-RPC endpoint and let a
   web dashboard hook in without a separate control channel.
4. **Cross-arch cert format compatibility.** Ed25519 self-signed certs
   generated on any platform should be byte-identical on any other. Worth
   verifying in test on `linux/arm/v7` specifically (32-bit BIGNUM path
   in OpenSSL has surfaced portability issues historically).

---

## 11. References

- `mrefd/interlinks.cpp:58` — current interlink file parser.
- `mrefd/interlink.cpp:45` — hostname-rejection check.
- `mrefd/ip.cpp:43` — `getaddrinfo`-based address parser (unused by current
  interlink path; could be reused if hostnames were later accepted).
- `mrefd/example.cfg` — current runtime config schema.
- `mrefd/config/mrefd.interlink` — current interlink file format documentation.
- M17 Foundation protocol docs — https://m17project.org/
- Ed25519 signing scheme — RFC 8032.
- TLS raw public keys (alternative to self-signed certs) — RFC 7250.
