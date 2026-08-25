#!/bin/bash
# =============================================================================
# tls-genkey.sh - Generate an Ed25519 keypair + self-signed cert for use as a
#                 TLS interlink identity (either home-server or field-client).
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
Usage: tls-genkey.sh --identity <callsign-module> [options]

Generates an Ed25519 keypair and self-signed X.509 cert. The cert's
Subject CN is set to the identity string; the SPKI fingerprint is
printed for out-of-band sharing.

Required:
  --identity <string>       e.g. "W5GGW-B" (field) or "M17-HOM" (home).
                            Used as the cert's Subject CN.

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
[[ "$IDENTITY" =~ ^[A-Z0-9]+-[A-Z0-9]+$ ]] || \
    die "identity must be uppercase alphanumeric with a single '-', e.g. W5GGW-B"
[[ "$ROLE" == "field" || "$ROLE" == "home" ]] || \
    die "--role must be 'field' or 'home' (got '$ROLE')"
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
command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"

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
openssl req -x509 -newkey ed25519 -nodes \
    -days "$DAYS" \
    -subj "/CN=${IDENTITY}" \
    -addext "subjectAltName=DNS:${IDENTITY}" \
    -keyout "$KEY_FILE" \
    -out    "$CERT_FILE" \
    2>/dev/null

chmod 0600 "$KEY_FILE"
chmod 0644 "$CERT_FILE"

# ---- fingerprint ------------------------------------------------------------
# SPKI SHA-256 fingerprint (base64) - what mrefd will match against.
FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary \
    | openssl base64)

say "cert : $CERT_FILE"
say "key  : $KEY_FILE  (0600, keep private)"
say "identity fingerprint (SPKI SHA-256 base64):"
printf '%s\n' "$FINGERPRINT"

case "$ROLE" in
  field)
    cat >&2 <<NEXT

Next: send $CERT_FILE (the .crt only, NOT the .key) to your home
reflector's operator, along with:
  - identity:    ${IDENTITY}
  - fingerprint: ${FINGERPRINT}
  - modules you want to share

Home operator registers it with:
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
