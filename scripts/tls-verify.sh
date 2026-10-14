#!/bin/bash
# =============================================================================
# tls-verify.sh - On a field node: check that a hub is reachable and is the
#   hub you expect, before (or instead of) reading mrefd's log.
#
# For each hub (every tls: line in mrefd.interlink, or the one given with
# --host) it checks:
#   1. TCP connect   - is the port reachable through every firewall?
#   2. TLS handshake - presenting this node's key, as mrefd does
#   3. Hub identity  - does the hub's key match the pinned certificate
#                      (or --expect-fingerprint)?
# Whether the hub has registered *your* key and module is decided after the
# handshake; mrefd's log says that ("hub rejected us: ...").
# =============================================================================
set -euo pipefail
die()  { printf 'tls-verify: ERROR: %s\n' "$*" >&2; exit 2; }
say()  { printf 'tls-verify: %s\n' "$*" >&2; }
pass() { printf '  PASS  %s\n' "$*" >&2; }
fail() { printf '  FAIL  %s\n' "$*" >&2; FAILED=1; }
info() { printf '  INFO  %s\n' "$*" >&2; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-verify.sh [options]

With no options, checks every hub this node links to (its tls: lines).

  --host <name[:port]>         Check this hub instead.
  --cert <hub.crt>             Its certificate, to check its identity against.
  --expect-fingerprint <b64>   Or its fingerprint (as tls-genkey printed it).
  --config <dir>               Reflector config directory. Default: the
                               config/ next to these scripts.
  --timeout <sec>              Per-check timeout. Default: 10.

Exit: 0 all checks passed, 1 a check failed, 2 usage error.
EOF
}

HOST="" PIN_CERT="" EXPECT_FP="" CFG="" TIMEOUT=10 FAILED=0
while (( $# > 0 )); do
    case "$1" in
        --host)               HOST="${2:?}"; shift 2 ;;
        --port)               HOST="${HOST%%:*}:${2:?}"; shift 2 ;;
        --cert)               PIN_CERT="${2:?}"; shift 2 ;;
        --expect-fingerprint) EXPECT_FP="${2:?}"; shift 2 ;;
        --config)             CFG="${2:?}"; shift 2 ;;
        --timeout)            TIMEOUT="${2:?}"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "unknown argument: $1  (try --help)" ;;
    esac
done
set_config_dir "$CFG"
find_openssl

# This node's key, presented the way mrefd presents it; the hub won't
# complete a handshake without one.
CCERT="${TLS_DIR}/client.crt" CKEY="${TLS_DIR}/client.key"
CLIENT_ARGS=()
if [[ -r "$CCERT" && -r "$CKEY" ]]; then
    CLIENT_ARGS=(-cert "$CCERT" -key "$CKEY")
else
    say "no field key at $CCERT; the hub will refuse the handshake (make one with tls-genkey.sh)"
fi

# run_with_timeout <seconds> <cmd...> - portable (macOS has no timeout(1)).
run_with_timeout() {
    local t="$1"; shift
    "$@" & local pid=$!
    ( sleep "$t" && kill "$pid" 2>/dev/null ) & local killer=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$killer" 2>/dev/null || true
    wait "$killer" 2>/dev/null || true
    return $rc
}

# check_hub <label> <host:port> <pinned cert or ""> <expected fp or "">
check_hub() {
    local label="$1" target="$2" pin="$3" want="$4"
    local host="${target%:*}" port="${target##*:}"
    say "${label}: ${host}:${port}"

    if run_with_timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
        pass "TCP connect"
    else
        fail "TCP connect (DNS, routing, or TCP ${port} not open inbound on the hub)"
        return
    fi

    local log cert
    log=$(mktemp); cert=$(mktemp)
    : | run_with_timeout "$TIMEOUT" "$OPENSSL" s_client -connect "${host}:${port}" \
            -servername "$host" -showcerts "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}" > "$log" 2>&1 || true
    "$OPENSSL" x509 -outform PEM < "$log" > "$cert" 2>/dev/null || true
    if [[ ! -s "$cert" ]]; then
        fail "TLS handshake (is this an M17export hub on that port?)"
        sed -n '1,8s/^/        /p' "$log" >&2
        rm -f "$log" "$cert"; return
    fi
    if grep -qi "alert\|handshake failure" "$log"; then
        fail "TLS handshake: the hub refused this node's key at the TLS layer"
    else
        pass "TLS handshake"
    fi

    local got cn
    got=$(spki_fingerprint "$cert")
    cn=$(cert_cn "$cert")
    info "hub certificate: ${cn}, fingerprint ${got}"
    if [[ -z "$want" && -n "$pin" && -r "$pin" ]]; then
        want=$(spki_fingerprint "$pin")
    fi
    if [[ -z "$want" ]]; then
        info "nothing to compare its identity with (give --cert or --expect-fingerprint)"
    elif [[ "$got" == "$want" ]]; then
        pass "hub identity matches ${pin:-the expected fingerprint}"
    else
        fail "hub identity does NOT match: expected ${want}. The hub's key changed (get its new certificate and rerun tls-add-hub.sh) or this isn't the right hub"
    fi
    rm -f "$log" "$cert"
}

if [[ -n "$HOST" ]]; then
    [[ "$HOST" == *:* ]] || HOST="${HOST}:17000"
    check_hub "hub" "$HOST" "$PIN_CERT" "$EXPECT_FP"
else
    [[ -f "$INTERLINK" ]] || die "no $INTERLINK; give --host"
    n=0
    while read -r hub target pin; do
        # mrefd.interlink names the container path; find the file on this host.
        [[ -n "$pin" ]] && pin="${TLS_DIR}/${pin#"$CONTAINER_TLS_DIR"/}"
        check_hub "$hub" "$target" "$pin" ""
        n=$((n + 1))
    done < <(awk '{
            t = ""; p = ""
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^tls:/) t = substr($i, 5)
                if ($i ~ /^servercert:/) p = substr($i, 12)
            }
            if (t != "") { if (t !~ /:[0-9]+$/) t = t ":17000"; print toupper($1), t, p }
        }' "$INTERLINK")
    (( n > 0 )) || die "no tls: lines in $INTERLINK; give --host"
fi

if (( FAILED )); then
    say "one or more checks failed"
    exit 1
fi
say "all checks passed"
