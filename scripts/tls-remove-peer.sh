#!/bin/bash
# =============================================================================
# tls-remove-peer.sh - Revoke a field peer.
#
# Steps performed, in order:
#   1. Delete the peer's cert file from the local registry.
#   2. Remove the peer's line from mrefd.interlink.
#      (mrefd's file watcher picks up both changes within seconds.)
#   3. Break any live TLS session for this identity:
#        preferred: talk to mrefd's admin socket (DISCONNECT <identity>)
#        fallback:  read peer's current source IP from mrefd.json and
#                   install an iptables REJECT that drops the TCP session.
#
# Design: docs/tls-interlink-design.md §7.3
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TLS_DIR="${ROOT}/config/tls"
PEERS_DIR="${TLS_DIR}/peers"
INTERLINK="${ROOT}/config/mrefd.interlink"

# Path to mrefd's admin socket (Unix domain). Path on the *host* so we can
# talk to it directly without exec-ing into the container. When running under
# docker compose we bind-mount the container's /var/run/mrefd/ into the host
# path used below.
ADMIN_SOCK="${MREFD_ADMIN_SOCK:-/var/run/mrefd/admin.sock}"

# Where mrefd writes its JSON status (from mrefd.cfg's JsonPath). When mrefd
# runs in the container the container writes here; via the shared 'mrefd-log'
# volume the host can inspect it via `docker compose exec` or a bind mount.
JSON_STATUS_PATH="${MREFD_JSON_PATH:-/var/log/mrefd/mrefd.json}"

# ---- helpers ----------------------------------------------------------------
die() { printf 'tls-remove-peer: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-remove-peer: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: tls-remove-peer.sh --identity <callsign-module> [options]

Revokes a field peer registration. Deletes the peer's cert, removes the
matching interlink line, and closes any active TLS session for the peer.

Required:
  --identity <string>       Peer identity, e.g. "W5GGW-B".

Options:
  --keep-cert               Do not delete the cert file (leave for audit).
  --no-cutoff               Skip the live-session cutoff step (revocation
                            takes effect only for future connections).
  --iptables-only           Skip the admin-socket step; go straight to the
                            iptables fallback.
  --dry-run                 Report what would happen without changing state.
EOF
}

# ---- argument parsing -------------------------------------------------------
IDENTITY=""
KEEP_CERT=0
NO_CUTOFF=0
IPT_ONLY=0
DRY_RUN=0

while (( $# > 0 )); do
    case "$1" in
        --identity)       IDENTITY="${2:?}"; shift 2 ;;
        --keep-cert)      KEEP_CERT=1; shift ;;
        --no-cutoff)      NO_CUTOFF=1; shift ;;
        --iptables-only)  IPT_ONLY=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
[[ "$IDENTITY" =~ ^[A-Z0-9]+-[A-Z0-9]+$ ]] || \
    die "identity must be uppercase alphanumeric with a single '-' (got '$IDENTITY')"

DEST_CERT="${PEERS_DIR}/${IDENTITY}.pub.pem"

# ---- step 1: delete cert ----------------------------------------------------
if [[ -e "$DEST_CERT" ]]; then
    if (( KEEP_CERT )); then
        say "keeping cert file at $DEST_CERT (--keep-cert)"
    elif (( DRY_RUN )); then
        printf '  [dry-run] would remove cert: %s\n' "$DEST_CERT" >&2
    else
        rm -f -- "$DEST_CERT"
        say "removed cert: $DEST_CERT"
    fi
else
    say "no cert file found at $DEST_CERT (already gone or never registered)"
fi

# ---- step 2: strip interlink line -------------------------------------------
if [[ -f "$INTERLINK" ]]; then
    if grep -qE "^[[:space:]]*${IDENTITY}[[:space:]]" "$INTERLINK"; then
        if (( DRY_RUN )); then
            printf '  [dry-run] would remove line: ' >&2
            grep -E "^[[:space:]]*${IDENTITY}[[:space:]]" "$INTERLINK" >&2
        else
            # sed -i works with an empty suffix on GNU and requires one on BSD.
            # `-i.bak` + rm is the portable form.
            sed -i.bak "/^[[:space:]]*${IDENTITY}[[:space:]]/d" "$INTERLINK"
            rm -f "${INTERLINK}.bak"
            say "removed interlink line for '${IDENTITY}'"
        fi
    else
        say "no interlink line found for '${IDENTITY}'"
    fi
else
    say "no mrefd.interlink file at $INTERLINK (nothing to strip)"
fi

# ---- step 3: cut live session ----------------------------------------------
if (( NO_CUTOFF )); then
    say "skipping live-session cutoff (--no-cutoff)"
    exit 0
fi

cutoff_via_admin_socket() {
    if [[ ! -S "$ADMIN_SOCK" ]]; then
        return 1
    fi
    if ! command -v socat >/dev/null 2>&1 && ! command -v nc >/dev/null 2>&1; then
        say "admin socket present but neither socat nor nc is installed"
        return 1
    fi
    say "sending DISCONNECT ${IDENTITY} to admin socket ${ADMIN_SOCK}"
    if (( DRY_RUN )); then
        printf '  [dry-run] would send: DISCONNECT %s\n' "$IDENTITY" >&2
        return 0
    fi
    if command -v socat >/dev/null 2>&1; then
        printf 'DISCONNECT %s\n' "$IDENTITY" \
            | socat - UNIX-CONNECT:"$ADMIN_SOCK" || return 1
    else
        printf 'DISCONNECT %s\n' "$IDENTITY" \
            | nc -U "$ADMIN_SOCK" || return 1
    fi
    return 0
}

cutoff_via_iptables() {
    if ! command -v iptables >/dev/null 2>&1; then
        say "iptables not installed on this host; cannot force session close"
        return 1
    fi
    if [[ ! -r "$JSON_STATUS_PATH" ]]; then
        say "mrefd status JSON not readable at $JSON_STATUS_PATH; cannot look up peer IP"
        return 1
    fi

    # Look up the peer's current source IP from mrefd.json. The exact schema
    # depends on the mrefd version; this handles both a flat "peers" list
    # (older) and a "tls_peers" list (once the fork is running).
    #
    # We look for either "callsign" or "identity" == our IDENTITY and pull
    # the associated address field.
    local ip
    if command -v jq >/dev/null 2>&1; then
        ip=$(jq -r --arg id "$IDENTITY" '
            (.tls_peers // .peers // [])[]
            | select((.identity // .callsign) == $id)
            | (.ip // .addr // .source_ip // empty)
        ' "$JSON_STATUS_PATH" 2>/dev/null | head -1)
    else
        say "jq not installed; cannot parse mrefd.json for peer IP"
        return 1
    fi

    if [[ -z "$ip" ]]; then
        say "no active session found for '${IDENTITY}' in $JSON_STATUS_PATH"
        return 0    # nothing to cut off is a success
    fi

    say "installing iptables REJECT to drop live session from $ip"
    if (( DRY_RUN )); then
        printf '  [dry-run] would run: iptables -I INPUT -s %s -p tcp --dport 17000 -j REJECT --reject-with tcp-reset\n' "$ip" >&2
        return 0
    fi

    # Insert a REJECT rule for this source IP on the interlink TCP port.
    # tcp-reset closes the existing session cleanly; INSERT (not APPEND)
    # so we hit before any accept rules. Requires root.
    if [[ $EUID -ne 0 ]]; then
        say "iptables requires root; re-run with sudo to install the rule"
        say "manual command to run: sudo iptables -I INPUT -s $ip -p tcp --dport 17000 -j REJECT --reject-with tcp-reset"
        return 1
    fi
    iptables -I INPUT -s "$ip" -p tcp --dport 17000 \
        -j REJECT --reject-with tcp-reset
    say "iptables rule installed; live session will close on next packet"
    say "reminder: this rule is transient. Remove it once the peer's key is"
    say "well and truly gone: sudo iptables -D INPUT -s $ip -p tcp --dport 17000 -j REJECT --reject-with tcp-reset"
    return 0
}

if (( ! IPT_ONLY )); then
    if cutoff_via_admin_socket; then
        say "session cutoff sent via admin socket"
        exit 0
    fi
    say "admin socket unavailable; falling back to iptables"
fi

if ! cutoff_via_iptables; then
    say "revocation is recorded in config but active session (if any) was not forcibly closed"
fi
# Config revocation always succeeds even if session cutoff can't run here
# (e.g. on a workstation without iptables). Exit 0 so callers can chain.
exit 0
