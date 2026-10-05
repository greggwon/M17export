#!/bin/bash
# =============================================================================
# tls-rotate-server-cert.sh - Generate a new server keypair, back up the
#   current one, install the new one. Prints the new fingerprint for
#   redistribution to field operators.
#
# Existing TLS sessions will drop when mrefd's TLS listener next restarts.
#
# Design: docs/tls-interlink-design.md §7.5
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TLS_DIR="${ROOT}/config/tls"
CERT="${TLS_DIR}/server.crt"
KEY="${TLS_DIR}/server.key"

# ---- helpers ----------------------------------------------------------------
die() { printf 'tls-rotate: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-rotate: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: tls-rotate-server-cert.sh --identity <string> [options]

Rotates the reflector's TLS server credential. The old cert/key are moved
to a timestamped backup file alongside; new Ed25519 keypair is generated.

Required:
  --identity <string>       Subject CN for the new cert (e.g. "M17-HOM").
                            Typically the same as the previous server cert.

Options:
  --days <n>                Validity in days. Default: 3650.

After rotation:
  1. Restart the mrefd container so the new key takes effect:
       docker compose restart mrefd
  2. Publish the new fingerprint to your field operators out-of-band.
     Existing field boxes must have this new cert pinned before they can
     reconnect.
EOF
}

# ---- argument parsing -------------------------------------------------------
IDENTITY=""
DAYS=3650

while (( $# > 0 )); do
    case "$1" in
        --identity) IDENTITY="${2:?}"; shift 2 ;;
        --days)     DAYS="${2:?}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
[[ "$IDENTITY" =~ ^[A-Za-z0-9._-]+$ ]] || die "identity has unsafe characters"

# ---- back up existing ------------------------------------------------------
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKED_UP=0
if [[ -e "$CERT" || -e "$KEY" ]]; then
    say "backing up existing server cert/key with suffix .${STAMP}.bak"
    [[ -e "$CERT" ]] && mv "$CERT" "${CERT}.${STAMP}.bak"
    [[ -e "$KEY"  ]] && mv "$KEY"  "${KEY}.${STAMP}.bak"
    BACKED_UP=1
else
    say "no existing server cert/key found; generating fresh"
fi

# ---- generate the new pair via tls-genkey.sh -------------------------------
GENKEY="${ROOT}/scripts/tls-genkey.sh"
[[ -x "$GENKEY" ]] || die "cannot execute $GENKEY"

# tls-genkey computes prefix.crt / prefix.key, so pass the base without ext.
"$GENKEY" \
    --identity "$IDENTITY" \
    --role     home \
    --out      "${TLS_DIR}/server" \
    --days     "$DAYS"

# ---- next steps -------------------------------------------------------------
cat >&2 <<NEXT

Rotation complete.

Backed up (if present):
  ${CERT}.${STAMP}.bak
  ${KEY}.${STAMP}.bak

Next:
  1. Restart mrefd to pick up the new cert:
       docker compose restart mrefd
  2. Publish the new fingerprint (printed above) to your field operators.
     Each field box must replace its pinned server.pem before it can
     reconnect. Older field boxes still holding the old fingerprint will
     fail their TLS validation until updated.

Keep the .bak files until every field operator has confirmed migration.
NEXT
