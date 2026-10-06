#!/bin/bash
# =============================================================================
# tls-genkey.sh - Generate an Ed25519 keypair + self-signed cert for use as a
#                 TLS interlink identity (either home-server or field-client).
#
# Field role: ONE certificate per operator, CN = bare callsign (W5GGW). Every
# node that operator runs uses the same cert and asserts its own module in
# its mrefd.interlink line, so the hub names each node CALLSIGN-MODULE.
#
# Needs OpenSSL 1.1.1+ (Ed25519). macOS's /usr/bin/openssl is LibreSSL and
# can't do this; install Homebrew's openssl@3 or point OPENSSL at one.
#
# Design: docs/tls-interlink-design.md §7.1
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TLS_DIR="${ROOT}/config/tls"

# ---- helpers ----------------------------------------------------------------
die()  { printf 'tls-genkey: ERROR: %s\n' "$*" >&2; exit 1; }
say()  { printf 'tls-genkey: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: tls-genkey.sh --identity <callsign> [options]

Generates an Ed25519 keypair and self-signed X.509 cert. The cert's
Subject CN is set to the identity string; the SPKI fingerprint is
printed for out-of-band sharing.

Required:
  --identity <string>       Used as the cert's Subject CN.
                              field: the operator's bare callsign, e.g. W5GGW
                                     (no module - each node asserts its own)
                              home:  the reflector's name, e.g. M17-HOM

Options:
  --out <prefix>            Output prefix. Files written are <prefix>.crt
                            and <prefix>.key. Default: ./config/tls/client
                            (for --role field) or ./config/tls/server
                            (for --role home).
  --role <field|home>       Sets the default --out prefix. Default: field.
  --days <n>                Certificate validity in days. Default: 3650.
  --force                   Overwrite existing files.

Files created:
  <prefix>.crt    self-signed X.509 certificate  (0644)
  <prefix>.key    Ed25519 private key (PEM)      (0600)

Output:
  Prints the SPKI SHA-256 fingerprint (base64) to stdout.
EOF
}

# ---- argument parsing -------------------------------------------------------
IDENTITY=""
OUT_PREFIX=""
ROLE="field"
DAYS=3650
FORCE=0

while (( $# > 0 )); do
    case "$1" in
        --identity) IDENTITY="${2:?}"; shift 2 ;;
        --out)      OUT_PREFIX="${2:?}"; shift 2 ;;
        --role)     ROLE="${2:?}"; shift 2 ;;
        --days)     DAYS="${2:?}"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
[[ "$ROLE" == "field" || "$ROLE" == "home" ]] || \
    die "--role must be 'field' or 'home' (got '$ROLE')"
if [[ "$ROLE" == "field" ]]; then
    [[ "$IDENTITY" =~ ^[A-Z0-9/]{3,}$ ]] || \
        die "field identity must be your bare callsign in upper case, e.g. W5GGW (got '$IDENTITY'). One cert serves all your nodes; each node names its module in mrefd.interlink."
else
    [[ "$IDENTITY" =~ ^[A-Z0-9/-]{3,}$ ]] || \
        die "home identity must be upper-case letters, digits, '/' or '-', e.g. M17-HOM (got '$IDENTITY')"
fi
[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days must be an integer"

if [[ -z "$OUT_PREFIX" ]]; then
    case "$ROLE" in
        field) OUT_PREFIX="${TLS_DIR}/client" ;;
        home)  OUT_PREFIX="${TLS_DIR}/server" ;;
    esac
fi

CERT_FILE="${OUT_PREFIX}.crt"
KEY_FILE="${OUT_PREFIX}.key"

# ---- pre-flight checks ------------------------------------------------------
OPENSSL="${OPENSSL:-openssl}"
command -v "$OPENSSL" >/dev/null 2>&1 || die "openssl not found (set OPENSSL=/path/to/openssl)"
if "$OPENSSL" version 2>/dev/null | grep -q LibreSSL; then
    die "$("$OPENSSL" version) can't create Ed25519 certificates. On macOS: brew install openssl@3, then rerun with OPENSSL=\$(brew --prefix openssl@3)/bin/openssl"
fi

mkdir -p "$(dirname "$OUT_PREFIX")"

if [[ -e "$CERT_FILE" || -e "$KEY_FILE" ]]; then
    if (( FORCE )); then
        say "overwriting existing $CERT_FILE / $KEY_FILE (--force)"
    else
        die "$CERT_FILE or $KEY_FILE already exists; pass --force to overwrite"
    fi
fi

# ---- generate ---------------------------------------------------------------
say "generating Ed25519 keypair for identity '${IDENTITY}' (role=${ROLE})"

# Ed25519 signs itself; no digest algorithm needed on -x509.
if ! REQ_ERR=$("$OPENSSL" req -x509 -newkey ed25519 -nodes \
        -days "$DAYS" \
        -subj "/CN=${IDENTITY}" \
        -addext "subjectAltName=DNS:${IDENTITY}" \
        -keyout "$KEY_FILE" \
        -out    "$CERT_FILE" 2>&1); then
    printf '%s\n' "$REQ_ERR" >&2
    die "openssl could not create the certificate"
fi

chmod 0600 "$KEY_FILE"
chmod 0644 "$CERT_FILE"

# ---- fingerprint ------------------------------------------------------------
# SPKI SHA-256 fingerprint (base64) - what mrefd will match against.
FINGERPRINT=$("$OPENSSL" x509 -in "$CERT_FILE" -pubkey -noout \
    | "$OPENSSL" pkey -pubin -outform DER 2>/dev/null \
    | "$OPENSSL" dgst -sha256 -binary \
    | "$OPENSSL" base64)

say "cert : $CERT_FILE"
say "key  : $KEY_FILE  (0600, keep private)"
say "identity fingerprint (SPKI SHA-256 base64):"
printf '%s\n' "$FINGERPRINT"

case "$ROLE" in
  field)
    cat >&2 <<NEXT

Copy this same cert + key to every node you run. Each node picks its
module in its own mrefd.interlink, e.g. for module B:
  M17-HOM  B  tls:home.example.org:17000  servercert:/etc/mrefd/tls/home.pem
and is known at the hub as ${IDENTITY}-B.

Send $CERT_FILE (the .crt only, NOT the .key) to the hub's operator,
along with:
  - callsign:    ${IDENTITY}
  - fingerprint: ${FINGERPRINT}
  - the modules your nodes will use

Hub operator registers it once, for all your nodes:
  scripts/tls-add-peer.sh --identity ${IDENTITY} \\
      --cert <path-to-received.crt> --modules <BCD-etc>
NEXT
    ;;
  home)
    cat >&2 <<NEXT

Next: publish $CERT_FILE (the .crt only, NOT the .key) so field
operators can pin your identity. Anywhere your field ops can retrieve
it out-of-band is fine (your website, DVREF, direct handoff).

Publish this fingerprint alongside it for verification:
  ${FINGERPRINT}
NEXT
    ;;
esac
