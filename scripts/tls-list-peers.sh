#!/bin/bash
# =============================================================================
# tls-list-peers.sh - Print the current TLS peer registry.
#
# Reports for each registered operator key:
#   - callsign (the cert's CN)
#   - modules its nodes may assert, from the interlink line
#   - nodes currently connected with it, CALLSIGN-<module>@address
#     (from mrefd.json if available)
#   - cert SPKI SHA-256 fingerprint
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

OPENSSL="${OPENSSL:-openssl}"
command -v "$OPENSSL" >/dev/null 2>&1 || die "openssl not found (set OPENSSL=/path/to/openssl)"
if "$OPENSSL" version 2>/dev/null | grep -q LibreSSL; then
    die "$("$OPENSSL" version) can't read Ed25519 certificates. On macOS: brew install openssl@3, then rerun with OPENSSL=\$(brew --prefix openssl@3)/bin/openssl"
fi

# ---- gather -----------------------------------------------------------------
declare -a IDS FPS MODS STATES IPS

fingerprint() {
    "$OPENSSL" x509 -in "$1" -pubkey -noout 2>/dev/null \
        | "$OPENSSL" pkey -pubin -outform DER 2>/dev/null \
        | "$OPENSSL" dgst -sha256 -binary 2>/dev/null \
        | "$OPENSSL" base64
}

callsign_of() {
    "$OPENSSL" x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -E 's/.*CN=([^,]+).*/\1/'
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

# Connected nodes for an operator key: "CALL-B@1.2.3.4 CALL-C@5.6.7.8".
lookup_nodes() {
    local id="$1"
    if [[ -r "$JSON_STATUS_PATH" ]] && command -v jq >/dev/null 2>&1; then
        jq -r --arg id "$id" '
            (.TLS.Links // [])[]
            | select(.Direction == "incoming" and .Key == $id and .State == "connected")
            | "\(.Name)@\(.Address)"
        ' "$JSON_STATUS_PATH" 2>/dev/null | sort -u | paste -sd' ' -
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
    id=$(callsign_of "$cert")
    [[ -n "$id" ]] || id=$(basename "$cert" .pub.pem)
    IDS+=("$id")
    FPS+=("$(fingerprint "$cert")")
    MODS+=("$(modules_for "$id")")
    nodes=$(lookup_nodes "$id")
    if [[ -n "$nodes" ]]; then
        STATES+=("connected")
        IPS+=("$nodes")
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
    printf '%-10s  %-8s  %-9s  %-46s  %s\n' CALLSIGN MODULES STATE FINGERPRINT NODES
    printf '%-10s  %-8s  %-9s  %-46s  %s\n' -------- ------- ----- ----------- -----
    for i in "${!IDS[@]}"; do
        printf '%-10s  %-8s  %-9s  %-46s  %s\n' \
            "${IDS[i]}" "${MODS[i]:--}" "${STATES[i]}" "${FPS[i]}" "${IPS[i]:--}"
    done
}

render_json() {
    printf '{"peers":['
    local sep=""
    for i in "${!IDS[@]}"; do
        printf '%s{"callsign":"%s","modules":"%s","state":"%s","nodes":"%s","fingerprint":"%s"}' \
            "$sep" "${IDS[i]}" "${MODS[i]}" "${STATES[i]}" "${IPS[i]}" "${FPS[i]}"
        sep=","
    done
    printf ']}\n'
}

case "$FMT" in
    table) render_table ;;
    json)  render_json ;;
esac
