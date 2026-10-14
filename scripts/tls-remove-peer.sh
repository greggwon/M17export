#!/bin/bash
# =============================================================================
# tls-remove-peer.sh - On a hub: revoke an operator's key.
#
# Removes their mrefd.interlink line and certificate. Within seconds mrefd
# disconnects every node using that key (W5ABC-B, W5ABC-C, ...) and refuses
# them from then on. No restart.
#
# To drop just one of their modules, rerun tls-add-peer.sh with the modules
# they should keep; nodes on the removed module are disconnected.
# =============================================================================
set -euo pipefail
die() { printf 'tls-remove-peer: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-remove-peer: %s\n' "$*" >&2; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-remove-peer.sh --identity <callsign> [options]

  --identity <call>   The operator's callsign, e.g. W5ABC.
  --config <dir>      Reflector config directory. Default: config/ next to these scripts
  --keep-cert         Leave their certificate file in tls/peers/.
EOF
}

IDENTITY="" KEEP_CERT=0 CFG=""
while (( $# > 0 )); do
    case "$1" in
        --identity)  IDENTITY="$(upper "${2:?}")"; shift 2 ;;
        --config)    CFG="${2:?}"; shift 2 ;;
        --keep-cert) KEEP_CERT=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown argument: $1  (try --help)" ;;
    esac
done
[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
set_config_dir "$CFG"

CERT="${PEERS_DIR}/${IDENTITY//\//_}.pub.pem"
found=0
if [[ -f "$INTERLINK" ]] && awk -v n="$IDENTITY" 'toupper($1) == n {f=1} END {exit !f}' "$INTERLINK"; then
    drop_interlink_line "$IDENTITY"
    say "removed ${IDENTITY} from $INTERLINK"
    found=1
fi
if [[ -e "$CERT" ]] && (( ! KEEP_CERT )); then
    rm -f -- "$CERT"
    say "removed $CERT"
    found=1
fi
(( found )) || die "${IDENTITY} isn't registered here (see tls-list-peers.sh)"
say "mrefd disconnects ${IDENTITY}'s nodes within seconds; check with tls-list-peers.sh or the dashboard."
