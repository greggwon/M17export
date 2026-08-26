# Interlink choices — helping both sides agree

An interlink is a mutual agreement between two reflector operators. Both
have to configure the other in their `mrefd.interlink` file, and both
have to agree on which transport to use. Neither the IP-based nor the
TLS-based model is "the right answer" for every case — this doc is here
to help two operators talk through the choice without either side
feeling pushed.

---

## Two models, both supported

### IP-based UDP interlink — the community default

- Both sides list the other's IP + port + shared modules.
- No cert exchange, no new tooling to learn.
- Ban a peer by IP at the firewall.
- Well-understood across mrefd, urfd, XLXD; how the M17/DMR/D-STAR
  reflector world has run for years.

### TLS-authenticated interlink — added when it's worth it

- Both sides trade cert files; each pins the other's cert.
- Peer identity is tied to a keypair, not a network address.
- Works when a peer's public IP changes (event/ARES field kits,
  residential ISPs, CGNAT'd hosts).
- Useful for private meshes that shouldn't appear on dvref.

**Both models coexist in the same reflector.** Your `mrefd.interlink`
file can have some peers via UDP and some via TLS. Adding a TLS peer
doesn't require migrating any of your existing UDP peers — leave those
alone; add the TLS entry alongside.

---

## When to propose TLS

- The peer is a **mobile / event / ARES field kit** with an IP that
  changes venue-to-venue. IP-based interlink can't handle this without
  either DDNS gymnastics or hand-editing the file each event.
- You're building a **private mesh** (an ARES section, a club-internal
  network) that shouldn't be listed on dvref.
- The peer specifically wants **explicit cryptographic authentication**
  — e.g., a section coordinator running ARES infrastructure.
- One of you sits **behind a CGNAT** that breaks inbound UDP.

## When to stick with UDP

- The peer is a **fixed public reflector** with a stable IP.
- You just want to link two well-known reflectors — you already trust
  each other at the IP level and don't need more than that.
- The peer would find TLS overhead disproportionate to the value.

## When it doesn't matter

Most reflector-to-reflector interlinks between two public dvref-listed
reflectors will be fine with UDP forever. TLS is worth adopting where
it *specifically* solves a problem, not for its own sake.

---

## Talking with a reluctant peer

Not every operator will want to run TLS. That's fine. In order of least
friction:

1. **Just use UDP.** It's the default, works, and has been for years.
2. **Offer asymmetric adoption on your side.** Some of your peers can
   be TLS, some can be UDP. Your reflector doesn't care.
3. **If there's a specific concern**, address it or drop it. The
   interlink works either way.

Common concerns and honest answers:

- **"I don't want to manage keys."** Then don't. Peer with UDP. The
  system doesn't force TLS on anyone. If YOU need TLS with someone else
  (say, a field kit), that's between you and that peer — it doesn't
  affect this interlink.
- **"DNS is spoofable, I only trust IPs."** Fair. The TLS model doesn't
  rely on DNS for trust — server certs are pinned by fingerprint,
  distributed out-of-band. See `CERTS.md`. But if this concern rules
  out TLS for you, use UDP.
- **"What if I need to ban a peer?"** `iptables` still works for TLS
  sessions exactly like it does for UDP. Ban lists and per-callsign
  whitelist/blacklist files continue to work independently of transport.
- **"This is over-engineered for what we do."** Might be. If the
  interlink you're setting up doesn't have any of the "when to propose
  TLS" reasons above, it probably is. Use UDP.

The security posture of a reflector doesn't fall apart because some
peers are UDP. Your whitelists, blacklists, gatekeeper callsign rules,
and iptables ban lists all apply per-peer independent of transport.

---

## Side-by-side

|                                | UDP interlink        | TLS interlink            |
|--------------------------------|----------------------|--------------------------|
| Setup effort                   | Trivial              | One cert exchange        |
| Ongoing maintenance            | None                 | Rotation policy          |
| Works with dynamic peer IPs    | No                   | Yes                      |
| Peer authentication            | Source IP            | Cryptographic (Ed25519)  |
| Visible on dvref               | Yes                  | Optional                 |
| Requires new tooling           | No                   | `openssl` / helper script|
| Familiar to long-time ops      | Yes                  | Not yet                  |
| Ban-by-IP still available      | Yes                  | Yes                      |
| Coexists with the other model  | Yes                  | Yes                      |

---

## Two-way sign-off

Because both sides have to configure the interlink, treat the choice as
a joint decision. A short exchange when arranging the peering:

> "I've got an M17-XYZ instance and I'd like to interlink modules B and
> D with your reflector. I'm happy either way — do you have a preference
> for UDP or TLS? UDP is fine; I only need TLS if you're behind
> variable IPs or want cert-based auth."

If both say UDP, use UDP. If both say TLS, use TLS. If you disagree,
default to UDP (the lower-friction choice) and revisit TLS later if a
real reason to migrate comes up.
