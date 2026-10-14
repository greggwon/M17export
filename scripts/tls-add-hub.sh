#!/bin/bash
# =============================================================================
# tls-add-hub.sh - On a field node: link one module to a hub over TLS.
#
# Copies the hub's certificate into <config>/tls/hubs/ and writes the
# matching mrefd.interlink line:
#     M17-HUB  B  tls:hub.example.org:17000  servercert:/etc/mrefd/tls/hubs/M17-HUB.crt
# The node keeps the link up by itself (reconnecting after outages and
# address changes). Restart the node after adding or changing a hub.
# =============================================================================
set -euo pipefail
die() { printf 'tls-add-hub: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'tls-add-hub: %s\n' "$*" >&2; }
. "$(dirname "${BASH_SOURCE[0]}")/tls-common.sh"

usage() {
    cat <<EOF
Usage: tls-add-hub.sh --hub <M17-XXX> --host <name[:port]> --module <X> --cert <hub.crt>

  --hub <name>        The hub reflector's callsign, e.g. M17-HUB.
  --host <host>       Its address: hub.example.org or hub.example.org:17000.
  --module <X>        The one module this node links, e.g. B. The hub must
                      have registered your key for it.
  --cert <path>       The hub's certificate (.crt), from its operator.
  --config <dir>      Reflector config directory. Default: config/ next to these scripts
  --remove            Remove the link to --hub instead.
EOF
}

HUB="" HOST="" MODULE_IN="" CERT_SRC="" CFG="" REMOVE=0
while (( $# > 0 )); do
    case "$1" in
        --hub)      HUB="$(upper "${2:?}")"; shift 2 ;;
        --host)     HOST="${2:?}"; shift 2 ;;
        --module|--modules) MODULE_IN="${2:?}"; shift 2 ;;
        --cert)     CERT_SRC="${2:?}"; shift 2 ;;
        --config)   CFG="${2:?}"; shift 2 ;;
        --remove)   REMOVE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$HUB" ]] || { usage >&2; die "--hub is required"; }
[[ "$HUB" =~ ^[A-Z0-9/-]{3,}$ ]] || die "--hub should be the hub's callsign, e.g. M17-HUB (got '$HUB')"
set_config_dir "$CFG"
HUB_CERT="${HUBS_DIR}/${HUB//\//_}.crt"

if (( REMOVE )); then
    drop_interlink_line "$HUB"
    rm -f "$HUB_CERT"
    say "removed the link to ${HUB}; restart this node"
    exit 0
fi

[[ -n "$HOST" && -n "$MODULE_IN" && -n "$CERT_SRC" ]] || \
    { usage >&2; die "--host, --module and --cert are required"; }
MODULE=$(normalize_modules "$MODULE_IN") || die "--module must be a letter, e.g. B (got '$MODULE_IN')"
[[ "$MODULE" =~ ^[A-Z]$ ]] || \
    die "a node links one module per hub line (got '$MODULE'); run this once per module, each from its own node"

# Accept host, host:port, or tls://host:port.
HOST="${HOST#*://}"
HOST="${HOST%/}"
if [[ "$HOST" == *:*:* || "$HOST" == \[* ]]; then
    die "IPv6 literals aren't supported in tls: lines yet; use a DNS name"
fi
[[ "$HOST" == *:* ]] || HOST="${HOST}:17000"
[[ "${HOST##*:}" =~ ^[0-9]+$ ]] || die "bad port in --host '$HOST'"

[[ -f "$CERT_SRC" ]] || die "certificate not found: $CERT_SRC"
find_openssl
"$OPENSSL" x509 -in "$CERT_SRC" -noout 2>/dev/null || \
    die "$CERT_SRC isn't a PEM certificate"
CN=$(cert_cn "$CERT_SRC")
[[ "$CN" == "$HUB" ]] || say "note: the certificate is named '${CN}', not '${HUB}' (fine if that's the hub you mean)"
[[ -f "${TLS_DIR}/client.crt" && -f "${TLS_DIR}/client.key" ]] || \
    say "note: no field key yet at ${TLS_DIR}/client.crt; make one with tls-genkey.sh --identity <your callsign>"

mkdir -p "$HUBS_DIR"
touch "$INTERLINK"
install -m 0644 "$CERT_SRC" "$HUB_CERT"
drop_interlink_line "$HUB"
printf '%-10s %-3s tls:%s  servercert:%s/hubs/%s.crt\n' \
    "$HUB" "$MODULE" "$HOST" "$CONTAINER_TLS_DIR" "${HUB//\//_}" >> "$INTERLINK"

say "module ${MODULE} links to ${HUB} at ${HOST}"
say "hub certificate fingerprint $(spki_fingerprint "$HUB_CERT")  (check it with the hub's operator)"
say "restart this node to connect (make restart, or docker compose restart mrefd)"
