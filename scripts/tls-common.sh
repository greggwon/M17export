#!/bin/bash
# =============================================================================
# tls-common.sh - shared by the tls-*.sh scripts. Source it; don't run it.
#
# Every script accepts --config <dir>: the reflector's config directory, the
# one mounted at /etc/mrefd in the container. It holds mrefd.interlink and
# tls/. Default: $M17_CONFIG_DIR, else the config/ directory next to these
# scripts (a repo checkout), else /etc/mrefd (inside the mrefd image).
# =============================================================================

TLS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paths as mrefd sees them inside the container. mrefd.interlink lines use
# these, wherever the config directory lives on the host.
CONTAINER_TLS_DIR="/etc/mrefd/tls"

# set_config_dir [dir] - sets CONFIG_DIR, TLS_DIR, PEERS_DIR, HUBS_DIR, INTERLINK.
set_config_dir() {
    local dir="${1:-${M17_CONFIG_DIR:-}}"
    if [[ -z "$dir" ]]; then
        if [[ -d "${TLS_SCRIPTS_DIR}/../config" ]]; then
            dir="${TLS_SCRIPTS_DIR}/../config"
        else
            dir="/etc/mrefd"
        fi
    fi
    mkdir -p "$dir" 2>/dev/null || true
    [[ -d "$dir" ]] || die "config directory $dir doesn't exist"
    CONFIG_DIR="$(cd "$dir" && pwd)"
    TLS_DIR="${CONFIG_DIR}/tls"
    PEERS_DIR="${TLS_DIR}/peers"
    HUBS_DIR="${TLS_DIR}/hubs"
    INTERLINK="${CONFIG_DIR}/mrefd.interlink"
}

# find_openssl - sets OPENSSL to an OpenSSL that can do Ed25519. macOS ships
# LibreSSL as /usr/bin/openssl, which can't; Homebrew's openssl@3 is found
# automatically.
find_openssl() {
    local cand
    for cand in "${OPENSSL:-}" openssl \
                /opt/homebrew/opt/openssl@3/bin/openssl \
                /usr/local/opt/openssl@3/bin/openssl; do
        [[ -n "$cand" ]] || continue
        command -v "$cand" >/dev/null 2>&1 || continue
        if "$cand" version 2>/dev/null | grep -q '^OpenSSL [3-9]\|^OpenSSL 1\.1\.1'; then
            OPENSSL="$cand"
            return 0
        fi
    done
    die "need OpenSSL 1.1.1 or newer (for Ed25519 keys); $(openssl version 2>/dev/null || echo 'openssl not found').
  macOS:  brew install openssl@3   (then rerun; it's found automatically)
  Debian: sudo apt install openssl
  Or run this script from the mrefd image, which has everything it needs:
    docker run --rm --user \"\$(id -u):\$(id -g)\" -v \"\$PWD/config:/etc/mrefd\" \\
        --entrypoint $(basename "$0" .sh) ghcr.io/greggwon/mrefd:latest [args]"
}

# spki_fingerprint <cert.pem> - SPKI SHA-256 (base64), what mrefd matches on.
spki_fingerprint() {
    "$OPENSSL" x509 -in "$1" -pubkey -noout 2>/dev/null \
        | "$OPENSSL" pkey -pubin -outform DER 2>/dev/null \
        | "$OPENSSL" dgst -sha256 -binary \
        | "$OPENSSL" base64
}

# cert_cn <cert.pem> - the certificate's Subject CN.
cert_cn() {
    "$OPENSSL" x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -E 's/.*CN=([^,]+).*/\1/'
}

# normalize_modules <text> - module letters written any reasonable way
# (BCD, B,C,D, "b c d", b/c/d) printed as B,C,D. Fails on anything else.
normalize_modules() {
    local in out="" c i
    in=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' \t,;/|+')
    [[ -n "$in" && "$in" =~ ^[A-Z]+$ ]] || return 1
    for (( i=0; i<${#in}; i++ )); do
        c="${in:i:1}"
        [[ "$out" == *"$c"* ]] || out+="$c"
    done
    printf '%s' "$out" | sed -e 's/./&,/g' -e 's/,$//'
}

# upper <text>
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Remove every mrefd.interlink line whose first word is $1.
drop_interlink_line() {
    local name="$1" tmp
    [[ -f "$INTERLINK" ]] || return 0
    tmp=$(mktemp)
    awk -v n="$name" 'toupper($1) != n' "$INTERLINK" > "$tmp"
    # Rewrite in place (keeps the inode, which a single-file bind mount needs).
    cat "$tmp" > "$INTERLINK"
    rm -f "$tmp"
}
