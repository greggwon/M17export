#!/bin/bash
# =============================================================================
# tls-add-peer.sh - Register an operator's public cert on the home reflector.
#                   Copies the cert into ./config/tls/peers/ and appends the
#                   matching line to ./config/mrefd.interlink. mrefd's file
#                   watcher picks up the change within seconds.
#
#                   One registration per operator key. Every node holding that
#                   key may connect, asserting one of --modules, and appears
#                   at this hub as CALLSIGN-MODULE.
#
# Design: docs/tls-interlink-design.md §7.2
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TLS_DIR="${ROOT}/config/tls"
PEERS_DIR="${TLS_DIR}/peers"
INTERLINK="${ROOT}/config/mrefd.interlink"

# Path inside the container that maps to $PEERS_DIR on the host.
# Whatever we write in mrefd.interlink is what mrefd reads INSIDE the container.
CONTAINER_PEERS_DIR="/etc/mrefd/tls/peers"

# ---- helpers ----------------------------------------------------------------
die() { printf 'tls-add-peer: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-add-peer: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: tls-add-peer.sh --identity <callsign> --cert <path> --modules <ABC> [options]

Registers an operator's key on this home reflector. Copies the public cert
into the local peer registry and appends the matching line to
mrefd.interlink. Any node presenting this key may then connect, asserting
one of the listed modules; it is named CALLSIGN-MODULE here.

Required:
  --identity <string>       Operator's bare callsign; must match the cert's
                            CN, e.g. "W5GGW".
  --cert <path>             Path to the operator's public cert file (PEM).
  --modules <string>        Modules the operator's nodes may assert, e.g. "BCD".

Options:
  --force                   Replace an existing registration for this callsign.
EOF
}

# ---- argument parsing -------------------------------------------------------
IDENTITY=""
CERT_SRC=""
MODULES=""
FORCE=0

while (( $# > 0 )); do
    case "$1" in
        --identity) IDENTITY="${2:?}"; shift 2 ;;
        --cert)     CERT_SRC="${2:?}"; shift 2 ;;
        --modules)  MODULES="${2:?}"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
[[ -n "$CERT_SRC" ]] || { usage >&2; die "--cert is required"; }
[[ -n "$MODULES"  ]] || { usage >&2; die "--modules is required"; }

[[ "$IDENTITY" =~ ^[A-Z0-9/]{3,}$ ]] || \
    die "identity must be the operator's bare callsign in upper case, e.g. W5GGW (got '$IDENTITY'); nodes add their module when they connect"
[[ "$MODULES"  =~ ^[A-Z]+$ ]] || \
    die "modules must be uppercase A-Z only (got '$MODULES')"
[[ -f "$CERT_SRC" ]] || die "cert file not found: $CERT_SRC"

OPENSSL="${OPENSSL:-openssl}"
command -v "$OPENSSL" >/dev/null 2>&1 || die "openssl not found (set OPENSSL=/path/to/openssl)"
if "$OPENSSL" version 2>/dev/null | grep -q LibreSSL; then
    die "$("$OPENSSL" version) can't read Ed25519 certificates. On macOS: brew install openssl@3, then rerun with OPENSSL=\$(brew --prefix openssl@3)/bin/openssl"
fi

# ---- validate the cert ------------------------------------------------------
# 1. Must be a parseable X.509 PEM certificate.
"$OPENSSL" x509 -in "$CERT_SRC" -noout 2>/dev/null || \
    die "$CERT_SRC does not parse as an X.509 PEM certificate"

# 2. Cert's Subject CN must match the given identity.
CERT_CN=$("$OPENSSL" x509 -in "$CERT_SRC" -noout -subject -nameopt RFC2253 \
    | sed -E 's/.*CN=([^,]+).*/\1/')
if [[ "$CERT_CN" != "$IDENTITY" ]]; then
    die "cert's Subject CN is '${CERT_CN}', does not match --identity '${IDENTITY}'"
fi

# 3. Compute the SPKI fingerprint for logging + duplicate-check.
FINGERPRINT=$("$OPENSSL" x509 -in "$CERT_SRC" -pubkey -noout \
    | "$OPENSSL" pkey -pubin -outform DER 2>/dev/null \
    | "$OPENSSL" dgst -sha256 -binary \
    | "$OPENSSL" base64)

# ---- ensure directories -----------------------------------------------------
mkdir -p "$PEERS_DIR"
touch "$INTERLINK"

# '/' (portable callsigns like W5GGW/P) can't appear in a filename.
FILE_ID="${IDENTITY//\//_}"
DEST_CERT="${PEERS_DIR}/${FILE_ID}.pub.pem"
CONTAINER_CERT="${CONTAINER_PEERS_DIR}/${FILE_ID}.pub.pem"

# ---- duplicate check --------------------------------------------------------
if [[ -e "$DEST_CERT" ]]; then
    EXISTING_FP=$("$OPENSSL" x509 -in "$DEST_CERT" -pubkey -noout \
        | "$OPENSSL" pkey -pubin -outform DER 2>/dev/null \
        | "$OPENSSL" dgst -sha256 -binary \
        | "$OPENSSL" base64)
    if [[ "$EXISTING_FP" == "$FINGERPRINT" ]]; then
        say "identity '${IDENTITY}' is already registered with this exact cert."
        say "nothing to do."
        exit 0
    fi
    if (( ! FORCE )); then
        die "identity '${IDENTITY}' is already registered with a different cert
    existing fingerprint: ${EXISTING_FP}
    new fingerprint:      ${FINGERPRINT}
Pass --force to replace."
    fi
    say "replacing existing registration for '${IDENTITY}' (--force)"
fi

# Also refuse if a *different* identity in the registry already uses this cert.
if [[ -d "$PEERS_DIR" ]]; then
    for existing in "$PEERS_DIR"/*.pub.pem; do
        [[ -e "$existing" ]] || continue
        [[ "$existing" == "$DEST_CERT" ]] && continue
        EFP=$("$OPENSSL" x509 -in "$existing" -pubkey -noout \
            | "$OPENSSL" pkey -pubin -outform DER 2>/dev/null \
            | "$OPENSSL" dgst -sha256 -binary \
            | "$OPENSSL" base64)
        if [[ "$EFP" == "$FINGERPRINT" ]]; then
            other=$(basename "$existing" .pub.pem)
            die "this cert's fingerprint is already registered as identity '${other}'"
        fi
    done
fi

# ---- install ----------------------------------------------------------------
install -m 0644 "$CERT_SRC" "$DEST_CERT"
say "installed cert -> $DEST_CERT"

# Remove any stale interlink line for this identity, then append fresh one.
if grep -qE "^[[:space:]]*${IDENTITY}[[:space:]]" "$INTERLINK" 2>/dev/null; then
    tmp=$(mktemp)
    grep -vE "^[[:space:]]*${IDENTITY}[[:space:]]" "$INTERLINK" > "$tmp"
    mv "$tmp" "$INTERLINK"
    say "removed stale interlink line for '${IDENTITY}'"
fi

printf '%-14s %-6s key:%s\n' "$IDENTITY" "$MODULES" "$CONTAINER_CERT" >> "$INTERLINK"
say "appended interlink line: ${IDENTITY} ${MODULES} key:${CONTAINER_CERT}"
say "fingerprint: ${FINGERPRINT}"
say "done. mrefd will pick up the change on its next file-watch cycle."
say "nodes using this key connect as ${IDENTITY}-<module>, module one of ${MODULES}."
