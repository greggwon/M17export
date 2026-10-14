#!/bin/bash
# =============================================================================
# tls-list-peers.sh - Show this reflector's TLS links.
#
# On a hub: each registered operator key, the modules its nodes may use,
# which of its nodes are connected now (CALLSIGN-MODULE@address), and the
# key's fingerprint.
# On a field node: each hub it links to and whether that link is up.
# =============================================================================
set -euo pipefail
die() { printf 'tls-list-peers: ERROR: %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-list-peers.sh [options]

  --config <dir>        Reflector config directory. Default: config/ next to these scripts
  --json                Emit JSON instead of a table.
  --status-file <path>  mrefd.json to read connection state from. Default:
                        \$MREFD_JSON_PATH, /var/log/mrefd/mrefd.json, or the
                        running mrefd container's copy (via docker exec).
EOF
}

FMT=table CFG="" JSON_STATUS_PATH="${MREFD_JSON_PATH:-/var/log/mrefd/mrefd.json}"
while (( $# > 0 )); do
    case "$1" in
        --json)         FMT=json; shift ;;
        --config)       CFG="${2:?}"; shift 2 ;;
        --status-file)  JSON_STATUS_PATH="${2:?}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown argument: $1  (try --help)" ;;
    esac
done
set_config_dir "$CFG"
find_openssl

# mrefd's live status. On the host it sits in a docker volume, so read it
# through the container when the file itself isn't reachable.
STATUS=""
if [[ -r "$JSON_STATUS_PATH" ]]; then
    STATUS=$(cat "$JSON_STATUS_PATH")
elif command -v docker >/dev/null 2>&1; then
    STATUS=$(docker exec mrefd cat /var/log/mrefd/mrefd.json 2>/dev/null || true)
fi
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

modules_for() {
    [[ -f "$INTERLINK" ]] || return 0
    local m
    m=$(awk -v id="$1" '
        toupper($1) == id {
            m = ""
            for (i = 2; i <= NF; i++)
                if ($i !~ /^(key|tls|servercert):/) m = m $i
            print m; exit
        }' "$INTERLINK")
    normalize_modules "$m" 2>/dev/null || printf '%s' "$m"
}

links() {   # links <jq filter producing lines>
    [[ -n "$STATUS" ]] && (( HAVE_JQ )) || return 0
    printf '%s' "$STATUS" | jq -r "$1" 2>/dev/null
}

# ---- hub side: registered operator keys -------------------------------------
declare -a IDS FPS MODS STATES NODES
shopt -s nullglob
for cert in "$PEERS_DIR"/*.pub.pem; do
    id=$(cert_cn "$cert")
    [[ -n "$id" ]] || id=$(basename "$cert" .pub.pem)
    nodes=$(links "(.TLS.Links // [])[]
        | select(.Direction == \"incoming\" and .Key == \"$id\" and .State == \"connected\")
        | \"\(.Name)@\(.Address)\"" | sort -u | paste -sd' ' -)
    IDS+=("$id")
    FPS+=("$(spki_fingerprint "$cert")")
    MODS+=("$(modules_for "$id")")
    if [[ -n "$nodes" ]]; then STATES+=("connected"); else STATES+=("idle"); fi
    NODES+=("$nodes")
done

# ---- field side: hubs this node links to -------------------------------------
declare -a HUBS HMODS HHOSTS HSTATES
if [[ -f "$INTERLINK" ]]; then
    while read -r hub mod host; do
        state=$(links "(.TLS.Links // [])[]
            | select(.Direction == \"outgoing\" and .Name == \"$hub\")
            | .State + (if .LastError != \"\" and .State != \"connected\" then \" (\" + .LastError + \")\" else \"\" end)" | head -1)
        HUBS+=("$hub"); HMODS+=("$mod"); HHOSTS+=("$host"); HSTATES+=("${state:-unknown}")
    done < <(awk '{
            host = ""; mod = ""
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^tls:/) host = substr($i, 5)
                else if ($i !~ /^(key|servercert):/) mod = mod $i
            }
            if (host != "") print toupper($1), toupper(mod), host
        }' "$INTERLINK")
fi

# ---- render -----------------------------------------------------------------
if [[ "$FMT" == "json" ]]; then
    printf '{"peers":['
    sep=""
    for i in "${!IDS[@]}"; do
        printf '%s{"callsign":"%s","modules":"%s","state":"%s","nodes":"%s","fingerprint":"%s"}' \
            "$sep" "${IDS[i]}" "${MODS[i]}" "${STATES[i]}" "${NODES[i]}" "${FPS[i]}"
        sep=","
    done
    printf '],"hubs":['
    sep=""
    for i in "${!HUBS[@]}"; do
        printf '%s{"hub":"%s","module":"%s","host":"%s","state":"%s"}' \
            "$sep" "${HUBS[i]}" "${HMODS[i]}" "${HHOSTS[i]}" "${HSTATES[i]}"
        sep=","
    done
    printf ']}\n'
    exit 0
fi

if (( ${#IDS[@]} == 0 && ${#HUBS[@]} == 0 )); then
    echo "No TLS links configured in $CONFIG_DIR."
    exit 0
fi
if (( ${#IDS[@]} > 0 )); then
    echo "Operator keys registered on this hub:"
    printf '  %-10s  %-8s  %-9s  %-46s  %s\n' CALLSIGN MODULES STATE FINGERPRINT NODES
    for i in "${!IDS[@]}"; do
        printf '  %-10s  %-8s  %-9s  %-46s  %s\n' \
            "${IDS[i]}" "${MODS[i]:--}" "${STATES[i]}" "${FPS[i]}" "${NODES[i]:--}"
    done
fi
if (( ${#HUBS[@]} > 0 )); then
    (( ${#IDS[@]} > 0 )) && echo
    echo "Hubs this node links to:"
    printf '  %-10s  %-6s  %-32s  %s\n' HUB MODULE ADDRESS STATE
    for i in "${!HUBS[@]}"; do
        printf '  %-10s  %-6s  %-32s  %s\n' "${HUBS[i]}" "${HMODS[i]}" "${HHOSTS[i]}" "${HSTATES[i]}"
    done
fi
if [[ -z "$STATUS" ]]; then
    echo
    echo "(connection state unavailable: mrefd.json not found and no running 'mrefd' container)"
elif (( ! HAVE_JQ )); then
    echo
    echo "(install jq to see connection state)"
fi
