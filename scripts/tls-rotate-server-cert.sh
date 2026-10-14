#!/bin/bash
# =============================================================================
# tls-rotate-server-cert.sh - On a hub: replace the hub's key and certificate.
#
# The old pair is kept as *.<timestamp>.bak. Every field operator linking to
# this hub needs the new certificate (tls-add-hub.sh again) before their
# nodes can reconnect, so plan it with them.
# =============================================================================
set -euo pipefail
die() { printf 'tls-rotate: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-rotate: %s\n' "$*" >&2; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-rotate-server-cert.sh --identity <M17-XXX> [options]

  --identity <name>   The hub's callsign, e.g. M17-HUB.
  --config <dir>      Reflector config directory. Default: config/ next to these scripts
  --days <n>          Validity in days. Default: 3650.
EOF
}

IDENTITY="" DAYS=3650 CFG=""
while (( $# > 0 )); do
    case "$1" in
        --identity) IDENTITY="$(upper "${2:?}")"; shift 2 ;;
        --config)   CFG="${2:?}"; shift 2 ;;
        --days)     DAYS="${2:?}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done
[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
set_config_dir "$CFG"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
for f in server.crt server.key; do
    if [[ -e "${TLS_DIR}/$f" ]]; then
        mv "${TLS_DIR}/$f" "${TLS_DIR}/$f.${STAMP}.bak"
        say "kept the old $f as $f.${STAMP}.bak"
    fi
done

GENKEY="${TLS_SCRIPTS_DIR}/tls-genkey.sh"
[[ -x "$GENKEY" ]] || GENKEY="${TLS_SCRIPTS_DIR}/tls-genkey"    # as installed in the image
"$GENKEY" --identity "$IDENTITY" --role hub \
    --config "$CONFIG_DIR" --days "$DAYS" 2>/dev/null | sed 's/^/new fingerprint: /'

cat >&2 <<NEXT

Next:
  1. Restart the hub:  make restart   (or docker compose restart mrefd)
  2. Send ${TLS_DIR}/server.crt and the new fingerprint to every field
     operator. Each one reruns tls-add-hub.sh with it and restarts their
     node; until then their nodes can't connect.
NEXT
