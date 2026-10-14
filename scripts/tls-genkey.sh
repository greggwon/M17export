#!/bin/bash
# =============================================================================
# tls-genkey.sh - Make this reflector's TLS key and certificate.
#
#   field node: one key per operator, named with your bare callsign (W5ABC).
#               Copy it to every node you run; each node names its own
#               module, and the hub sees it as W5ABC-B, W5ABC-C, ...
#   hub:        one key per hub, named with the reflector's callsign (M17-HUB).
#
# Writes <config>/tls/client.{crt,key} (field) or server.{crt,key} (hub).
# The entrypoint finds them there; no .env settings are needed.
# =============================================================================
set -euo pipefail
die() { printf 'tls-genkey: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-genkey: %s\n' "$*" >&2; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-genkey.sh --identity <callsign> [--role field|hub] [options]

  --identity <name>   field: your bare callsign, e.g. W5ABC (no module)
                      hub:   the reflector's callsign, e.g. M17-HUB
  --role field|hub    Default: field. ("home" is accepted for hub.)
  --config <dir>      Reflector config directory. Default: config/ next to these scripts
  --out <prefix>      Write <prefix>.crt / <prefix>.key instead of
                      <config>/tls/client or <config>/tls/server.
  --days <n>          Validity in days. Default: 3650.
  --force             Replace an existing key.

Prints the key's fingerprint (SPKI SHA-256, base64) for checking by phone
or email with whoever you exchange certificates with.
EOF
}

IDENTITY="" OUT_PREFIX="" ROLE="field" DAYS=3650 FORCE=0 CFG=""
while (( $# > 0 )); do
    case "$1" in
        --identity) IDENTITY="$(upper "${2:?}")"; shift 2 ;;
        --out)      OUT_PREFIX="${2:?}"; shift 2 ;;
        --role)     ROLE="${2:?}"; shift 2 ;;
        --config)   CFG="${2:?}"; shift 2 ;;
        --days)     DAYS="${2:?}"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
case "$ROLE" in
    field)    ;;
    hub|home) ROLE=hub ;;
    *)        die "--role must be 'field' or 'hub' (got '$ROLE')" ;;
esac
if [[ "$ROLE" == "field" ]]; then
    [[ "$IDENTITY" =~ ^[A-Z0-9/]{3,}$ ]] || \
        die "a field key is named with your bare callsign, e.g. W5ABC (got '$IDENTITY'). One key serves all your nodes; each node names its module in mrefd.interlink."
else
    [[ "$IDENTITY" =~ ^[A-Z0-9/-]{3,}$ ]] || \
        die "a hub key is named with the reflector's callsign, e.g. M17-HUB (got '$IDENTITY')"
fi
[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days must be a number"

set_config_dir "$CFG"
find_openssl
if [[ -z "$OUT_PREFIX" ]]; then
    [[ "$ROLE" == "field" ]] && OUT_PREFIX="${TLS_DIR}/client" || OUT_PREFIX="${TLS_DIR}/server"
fi
CERT_FILE="${OUT_PREFIX}.crt"
KEY_FILE="${OUT_PREFIX}.key"
mkdir -p "$(dirname "$OUT_PREFIX")"

if [[ -e "$CERT_FILE" || -e "$KEY_FILE" ]]; then
    (( FORCE )) || die "$CERT_FILE already exists; pass --force to replace it (everyone holding the old certificate will need the new one)"
    say "replacing $CERT_FILE / $KEY_FILE (--force)"
fi

if ! ERR=$("$OPENSSL" req -x509 -newkey ed25519 -nodes -days "$DAYS" \
        -subj "/CN=${IDENTITY}" -addext "subjectAltName=DNS:${IDENTITY}" \
        -keyout "$KEY_FILE" -out "$CERT_FILE" 2>&1); then
    printf '%s\n' "$ERR" >&2
    die "openssl could not create the certificate"
fi
chmod 0600 "$KEY_FILE"
chmod 0644 "$CERT_FILE"
# The container runs mrefd as uid 1000; it must be able to read the key.
if [[ "$(id -u)" == 0 ]]; then chown 1000:1000 "$KEY_FILE" 2>/dev/null || true; fi

FINGERPRINT=$(spki_fingerprint "$CERT_FILE")
say "certificate: $CERT_FILE"
say "private key: $KEY_FILE  (keep it private; never send it)"
printf '%s\n' "$FINGERPRINT"

if [[ "$ROLE" == "field" ]]; then
    cat >&2 <<NEXT

Next:
  1. Send $CERT_FILE (not the .key) to the hub's operator, with your
     callsign and the modules your nodes will use. Read them the
     fingerprint above so they can check it arrived intact.
  2. They send you their hub certificate. Then on this node:
       scripts/tls-add-hub.sh --hub M17-HUB --host hub.example.org \\
           --module B --cert <their-hub.crt>
  3. Restart this node. Every node you run uses this same key; copy the
     whole config/tls directory to each one.
NEXT
else
    cat >&2 <<NEXT

Next:
  1. Give $CERT_FILE (not the .key) and the fingerprint above to the
     operators whose nodes will link here.
  2. Register each operator's certificate when it arrives:
       scripts/tls-add-peer.sh --cert <their.crt> --modules B,C
     mrefd picks it up within seconds; no restart needed.
NEXT
fi
