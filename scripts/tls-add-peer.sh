#!/bin/bash
# =============================================================================
# tls-add-peer.sh - Register a field's public cert on the home reflector.
#                   Copies the cert into ./config/tls/peers/ and appends the
#                   matching line to ./config/mrefd.interlink. mrefd's file
#                   watcher picks up the change within seconds.
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
Usage: tls-add-peer.sh --identity <callsign-module> --cert <path> --modules <ABC> [options]

Registers a field peer on this home reflector. Copies the peer's public
cert into the local peer registry and appends the matching line to
mrefd.interlink so mrefd will accept an incoming TLS connection that
authenticates with the matching private key.

Required:
  --identity <string>       Peer identity string (must match the cert's CN),
                            e.g. "W5GGW-B".
  --cert <path>             Path to the peer's public cert file (PEM).
  --modules <string>        Modules this peer will share, e.g. "BCD".

Options:
  --force                   Replace an existing registration for this identity.
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

[[ "$IDENTITY" =~ ^[A-Z0-9]+-[A-Z0-9]+$ ]] || \
    die "identity must be uppercase alphanumeric with a single '-' (got '$IDENTITY')"
[[ "$MODULES"  =~ ^[A-Z]+$ ]] || \
    die "modules must be uppercase A-Z only (got '$MODULES')"
[[ -f "$CERT_SRC" ]] || die "cert file not found: $CERT_SRC"

command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"

# ---- validate the cert ------------------------------------------------------
# 1. Must be a parseable X.509 PEM certificate.
openssl x509 -in "$CERT_SRC" -noout 2>/dev/null || \
    die "$CERT_SRC does not parse as an X.509 PEM certificate"

# 2. Cert's Subject CN must match the given identity.
CERT_CN=$(openssl x509 -in "$CERT_SRC" -noout -subject -nameopt RFC2253 \
    | sed -E 's/.*CN=([^,]+).*/\1/')
if [[ "$CERT_CN" != "$IDENTITY" ]]; then
    die "cert's Subject CN is '${CERT_CN}', does not match --identity '${IDENTITY}'"
fi

# 3. Compute the SPKI fingerprint for logging + duplicate-check.
FINGERPRINT=$(openssl x509 -in "$CERT_SRC" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary \
    | openssl base64)

# ---- ensure directories -----------------------------------------------------
mkdir -p "$PEERS_DIR"
touch "$INTERLINK"

DEST_CERT="${PEERS_DIR}/${IDENTITY}.pub.pem"
CONTAINER_CERT="${CONTAINER_PEERS_DIR}/${IDENTITY}.pub.pem"

# ---- duplicate check --------------------------------------------------------
if [[ -e "$DEST_CERT" ]]; then
    EXISTING_FP=$(openssl x509 -in "$DEST_CERT" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | openssl base64)
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
        EFP=$(openssl x509 -in "$existing" -pubkey -noout \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | openssl dgst -sha256 -binary \
            | openssl base64)
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
