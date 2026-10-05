#!/bin/bash
# =============================================================================
# tls-list-peers.sh - Print the current TLS peer registry.
#
# Reports for each registered peer:
#   - identity (callsign-<module>)
#   - cert SPKI SHA-256 fingerprint
#   - modules from the interlink line
#   - active session state (from mrefd.json if available)
#
# Design: docs/tls-interlink-design.md §7.4
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TLS_DIR="${ROOT}/config/tls"
PEERS_DIR="${TLS_DIR}/peers"
INTERLINK="${ROOT}/config/mrefd.interlink"
JSON_STATUS_PATH="${MREFD_JSON_PATH:-/var/log/mrefd/mrefd.json}"

# ---- helpers ----------------------------------------------------------------
die() { printf 'tls-list-peers: ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: tls-list-peers.sh [options]

Prints the current TLS peer registry with connection state.

Options:
  --json                Emit as JSON instead of a formatted table.
  --status-file <path>  Path to mrefd.json. Default: \$MREFD_JSON_PATH or
                        /var/log/mrefd/mrefd.json.
EOF
}

FMT=table
while (( $# > 0 )); do
    case "$1" in
        --json)         FMT=json; shift ;;
        --status-file)  JSON_STATUS_PATH="${2:?}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown argument: $1  (try --help)" ;;
    esac
done

command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"

# ---- gather -----------------------------------------------------------------
declare -a IDS FPS MODS STATES IPS

fingerprint() {
    openssl x509 -in "$1" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl base64
}

modules_for() {
    local id="$1"
    if [[ -f "$INTERLINK" ]]; then
        awk -v id="$id" '
            $1 == id {
                for (i=2; i<=NF; i++) {
                    if ($i !~ /^key:/ && $i !~ /^tls:/ && $i !~ /^servercert:/) {
                        print $i; exit
                    }
                }
            }' "$INTERLINK"
    fi
}

lookup_session() {
    local id="$1"
    if [[ -r "$JSON_STATUS_PATH" ]] && command -v jq >/dev/null 2>&1; then
        local ip
        ip=$(jq -r --arg id "$id" '
            (.tls_peers // .peers // [])[]
            | select((.identity // .callsign) == $id)
            | (.ip // .addr // .source_ip // empty)
        ' "$JSON_STATUS_PATH" 2>/dev/null | head -1)
        printf '%s' "${ip:-}"
    fi
}

if [[ ! -d "$PEERS_DIR" ]]; then
    if [[ "$FMT" == "json" ]]; then
        echo '{"peers":[]}'
    else
        echo "(no peer registry at $PEERS_DIR)"
    fi
    exit 0
fi

shopt -s nullglob
for cert in "$PEERS_DIR"/*.pub.pem; do
    id=$(basename "$cert" .pub.pem)
    IDS+=("$id")
    FPS+=("$(fingerprint "$cert")")
    MODS+=("$(modules_for "$id")")
    ip=$(lookup_session "$id")
    if [[ -n "$ip" ]]; then
        STATES+=("connected")
        IPS+=("$ip")
    else
        STATES+=("idle")
        IPS+=("")
    fi
done

# ---- render -----------------------------------------------------------------
render_table() {
    if [[ ${#IDS[@]} -eq 0 ]]; then
        echo "(no peers registered)"
        return
    fi
    printf '%-14s  %-8s  %-9s  %-15s  %s\n' IDENTITY MODULES STATE ADDRESS FINGERPRINT
    printf '%-14s  %-8s  %-9s  %-15s  %s\n' -------- ------- ----- ------- -----------
    for i in "${!IDS[@]}"; do
        printf '%-14s  %-8s  %-9s  %-15s  %s\n' \
            "${IDS[i]}" "${MODS[i]:--}" "${STATES[i]}" "${IPS[i]:--}" "${FPS[i]}"
    done
}

render_json() {
    printf '{"peers":['
    local sep=""
    for i in "${!IDS[@]}"; do
        printf '%s{"identity":"%s","modules":"%s","state":"%s","address":"%s","fingerprint":"%s"}' \
            "$sep" "${IDS[i]}" "${MODS[i]}" "${STATES[i]}" "${IPS[i]}" "${FPS[i]}"
        sep=","
    done
    printf ']}\n'
}

case "$FMT" in
    table) render_table ;;
    json)  render_json ;;
esac
