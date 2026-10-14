#!/bin/bash
# =============================================================================
# tls-add-peer.sh - On a hub: let an operator's field nodes link in.
#
# Copies the operator's certificate into <config>/tls/peers/ and writes the
# matching mrefd.interlink line:
#     W5ABC  B,C  key:/etc/mrefd/tls/peers/W5ABC.pub.pem
# mrefd notices within seconds; no restart. Every node holding that
# operator's key may connect, naming one of the listed modules, and shows
# up here as W5ABC-B, W5ABC-C, ...
#
# Run it again with different --modules to change what they may use.
# =============================================================================
set -euo pipefail
die() { printf 'tls-add-peer: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-add-peer: %s\n' "$*" >&2; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-add-peer.sh --cert <their.crt> --modules <list> [options]

  --cert <path>        The operator's certificate (.crt / PEM).
  --modules <list>     Modules their nodes may use: B,C or BC or "b c".
  --identity <call>    Their callsign. Optional: read from the certificate;
                       if given, it must match.
  --config <dir>       Reflector config directory. Default: config/ next to these scripts
  --force              Replace a registration that has a different key.
EOF
}

IDENTITY="" CERT_SRC="" MODULES_IN="" FORCE=0 CFG=""
while (( $# > 0 )); do
    case "$1" in
        --identity) IDENTITY="$(upper "${2:?}")"; shift 2 ;;
        --cert)     CERT_SRC="${2:?}"; shift 2 ;;
        --modules)  MODULES_IN="${2:?}"; shift 2 ;;
        --config)   CFG="${2:?}"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$CERT_SRC" ]]   || { usage >&2; die "--cert is required"; }
[[ -n "$MODULES_IN" ]] || { usage >&2; die "--modules is required"; }
MODULES=$(normalize_modules "$MODULES_IN") || \
    die "--modules must be module letters, e.g. B,C (got '$MODULES_IN')"
[[ -f "$CERT_SRC" ]] || die "certificate not found: $CERT_SRC"

set_config_dir "$CFG"
find_openssl

"$OPENSSL" x509 -in "$CERT_SRC" -noout 2>/dev/null || \
    die "$CERT_SRC isn't a PEM certificate (did you get the .crt, not the .key?)"
CERT_CN=$(cert_cn "$CERT_SRC")
[[ -n "$IDENTITY" ]] || IDENTITY="$CERT_CN"
[[ "$CERT_CN" == "$IDENTITY" ]] || \
    die "the certificate is for '${CERT_CN}', not '${IDENTITY}'"
[[ "$IDENTITY" =~ ^[A-Z0-9/]{3,}$ ]] || \
    die "the certificate is named '${IDENTITY}'; a field key must be named with the operator's bare callsign, e.g. W5ABC (they should rerun tls-genkey.sh)"
FINGERPRINT=$(spki_fingerprint "$CERT_SRC")

mkdir -p "$PEERS_DIR"
touch "$INTERLINK"
FILE_ID="${IDENTITY//\//_}"      # '/' (W5ABC/P) can't be in a filename
DEST_CERT="${PEERS_DIR}/${FILE_ID}.pub.pem"

if [[ -e "$DEST_CERT" ]]; then
    OLD_FP=$(spki_fingerprint "$DEST_CERT")
    if [[ "$OLD_FP" != "$FINGERPRINT" ]] && (( ! FORCE )); then
        die "${IDENTITY} is already registered with a different key
    registered: ${OLD_FP}
    new:        ${FINGERPRINT}
If they made a new key, pass --force (their nodes on the old key are disconnected)."
    fi
fi
for other in "$PEERS_DIR"/*.pub.pem; do
    [[ -e "$other" && "$other" != "$DEST_CERT" ]] || continue
    if [[ "$(spki_fingerprint "$other")" == "$FINGERPRINT" ]]; then
        die "this key is already registered as $(basename "$other" .pub.pem)"
    fi
done

install -m 0644 "$CERT_SRC" "$DEST_CERT"
drop_interlink_line "$IDENTITY"
printf '%-10s %-8s key:%s/peers/%s.pub.pem\n' \
    "$IDENTITY" "$MODULES" "$CONTAINER_TLS_DIR" "$FILE_ID" >> "$INTERLINK"

say "registered ${IDENTITY}, modules ${MODULES}"
say "fingerprint ${FINGERPRINT}  (check it with ${IDENTITY})"
say "mrefd picks this up within seconds. Their nodes connect as ${IDENTITY}-<module>."
