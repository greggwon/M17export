#!/bin/bash
# =============================================================================
# tls-verify.sh - Diagnostic: attempt a TLS connection against a running mrefd
#   TLS listener and report the outcome of each stage.
#
# Reports:
#   1. TCP connect - can we reach the port at all?
#   2. TLS handshake - does the server present a cert, negotiate ciphers?
#   3. Server cert fingerprint match (if --expect-fingerprint given).
#   4. Server cert Subject CN.
#   5. Client cert presentation (if --client-cert given, informational only
#      here since mrefd's BIRTH exchange is a post-handshake application-layer
#      protocol; openssl s_client can't drive it).
#
# NOTE: this script does not exercise the M17 BIRTH message flow itself.
# That requires the mrefd binary to be built with TLS support. Once the
# reference implementation lands, this script gains an --exercise-birth
# flag that drives a full handshake through mrefd's own tools.
#
# Design: docs/tls-interlink-design.md §7.6
# =============================================================================
set -euo pipefail

# ---- helpers ----------------------------------------------------------------
die()  { printf 'tls-verify: ERROR: %s\n' "$*" >&2; exit 2; }
say()  { printf 'tls-verify: %s\n' "$*" >&2; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*" >&2; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; FAILED=1; }
info() { printf '  \033[34mINFO\033[0m  %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: tls-verify.sh --host <hostname-or-ip> [options]

Diagnostic TLS handshake against a running mrefd TLS listener. Reports the
outcome of each stage (TCP, TLS, cert match).

Required:
  --host <string>              Target reflector host or IP.

Options:
  --port <n>                   TCP port. Default: 17000.
  --client-cert <path>         Present this client cert during the handshake
                               (informational; mrefd auth happens at the
                               post-handshake BIRTH message).
  --client-key <path>          Private key matching --client-cert.
  --expect-fingerprint <b64>   Verify the server cert's SPKI SHA-256
                               fingerprint matches this value (base64).
  --timeout <sec>              Handshake timeout. Default: 5.

Exit codes:
  0   All checks passed.
  1   At least one check failed.
  2   Usage error or missing tool.
EOF
}

# ---- argument parsing -------------------------------------------------------
HOST=""
PORT=17000
CCERT=""
CKEY=""
EXPECT_FP=""
TIMEOUT=5
FAILED=0

while (( $# > 0 )); do
    case "$1" in
        --host)                HOST="${2:?}"; shift 2 ;;
        --port)                PORT="${2:?}"; shift 2 ;;
        --client-cert)         CCERT="${2:?}"; shift 2 ;;
        --client-key)          CKEY="${2:?}"; shift 2 ;;
        --expect-fingerprint)  EXPECT_FP="${2:?}"; shift 2 ;;
        --timeout)             TIMEOUT="${2:?}"; shift 2 ;;
        -h|--help)             usage; exit 0 ;;
        *)                     die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$HOST" ]] || { usage >&2; die "--host is required"; }
command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"

if [[ -n "$CCERT" && -z "$CKEY" ]] || [[ -z "$CCERT" && -n "$CKEY" ]]; then
    die "--client-cert and --client-key must be given together"
fi

say "target: ${HOST}:${PORT} (timeout=${TIMEOUT}s)"

# ---- stage 1: TCP connect ---------------------------------------------------
# Use bash's /dev/tcp for a portable port check.
if (exec 3<>/dev/tcp/"${HOST}"/"${PORT}") 2>/dev/null; then
    pass "TCP connect to ${HOST}:${PORT}"
    exec 3>&- 3<&-
else
    fail "TCP connect to ${HOST}:${PORT} (no route / port closed / filtered)"
    exit 1
fi

# ---- stage 2: TLS handshake -------------------------------------------------
SCLIENT_LOG=$(mktemp)
trap 'rm -f "$SCLIENT_LOG"' EXIT

SCLIENT_ARGS=(
    -connect "${HOST}:${PORT}"
    -servername "${HOST}"
    -verify_return_error
    -brief
)
if [[ -n "$CCERT" ]]; then
    SCLIENT_ARGS+=(-cert "$CCERT" -key "$CKEY")
fi

# Feed empty input so s_client tears down cleanly after handshake.
# Timeout via a small shell wrapper; -brief keeps stderr low-volume.
if : | openssl s_client "${SCLIENT_ARGS[@]}" > "$SCLIENT_LOG" 2>&1 \
     & SPID=$!
   # give it TIMEOUT seconds to complete
   ( sleep "$TIMEOUT" && kill "$SPID" 2>/dev/null ) & TPID=$!
   wait "$SPID" 2>/dev/null
   RC=$?
   kill "$TPID" 2>/dev/null || true
   wait "$TPID" 2>/dev/null || true
   [[ $RC -eq 0 ]]
then
    pass "TLS handshake succeeded"
else
    fail "TLS handshake failed (exit=$RC). openssl s_client output:"
    sed 's/^/        /' "$SCLIENT_LOG" >&2
    exit 1
fi

# ---- stage 3: server cert details -------------------------------------------
CERT_PEM=$(mktemp)
trap 'rm -f "$SCLIENT_LOG" "$CERT_PEM"' EXIT

: | openssl s_client -connect "${HOST}:${PORT}" -servername "${HOST}" \
        -showcerts 2>/dev/null \
        | openssl x509 -outform PEM > "$CERT_PEM" 2>/dev/null || true

if [[ ! -s "$CERT_PEM" ]]; then
    fail "could not extract server cert from handshake"
    exit 1
fi

SUBJECT=$(openssl x509 -in "$CERT_PEM" -noout -subject 2>/dev/null | sed 's/^subject=//')
info "server subject: ${SUBJECT}"

SERVER_FP=$(openssl x509 -in "$CERT_PEM" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary \
    | openssl base64)
info "server SPKI SHA-256: ${SERVER_FP}"

if [[ -n "$EXPECT_FP" ]]; then
    if [[ "$SERVER_FP" == "$EXPECT_FP" ]]; then
        pass "server fingerprint matches expected value"
    else
        fail "server fingerprint MISMATCH"
        info "  expected: ${EXPECT_FP}"
        info "  got:      ${SERVER_FP}"
    fi
fi

# ---- stage 4: client cert (informational) -----------------------------------
if [[ -n "$CCERT" ]]; then
    CCN=$(openssl x509 -in "$CCERT" -noout -subject 2>/dev/null | sed -E 's/.*CN=([^,]+).*/\1/')
    CFP=$(openssl x509 -in "$CCERT" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | openssl base64)
    info "client cert Subject CN: ${CCN}"
    info "client SPKI SHA-256:    ${CFP}"
    info "(mrefd BIRTH exchange happens after handshake and is not"
    info " exercised by this script; use mrefd's own client to test"
    info " end-to-end auth once the TLS reference implementation lands)"
fi

if (( FAILED )); then
    say "one or more checks failed"
    exit 1
fi

say "all checks passed"
exit 0
