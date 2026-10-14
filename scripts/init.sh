#!/bin/bash
# =============================================================================
# Interactive `make init` wizard.
# Prompts for the fields you can't sensibly default, writes .env, and drops
# stub whitelist/blacklist/interlink files into ./config/.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
CFG_DIR="${ROOT}/config"

# ---- helpers ----------------------------------------------------------------

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask()  {  # ask "prompt" "default" [validator-regex] [error-msg]
    local prompt="$1" default="${2:-}" re="${3:-}" errmsg="${4:-invalid value}"
    local hint="" val
    [[ -n "$default" ]] && hint=" [${default}]"
    while :; do
        read -r -p "  ${prompt}${hint}: " val
        val="${val:-$default}"
        if [[ -z "$val" ]]; then
            echo "    (required)" >&2
            continue
        fi
        if [[ -n "$re" && ! "$val" =~ $re ]]; then
            echo "    ${errmsg}" >&2
            continue
        fi
        printf '%s' "$val"
        return
    done
}

confirm_overwrite() {
    local path="$1"
    if [[ -e "$path" ]]; then
        read -r -p "  ${path} exists. Overwrite? [y/N]: " ans
        [[ "$ans" =~ ^[yY]$ ]] || return 1
    fi
    return 0
}

# ---- start ------------------------------------------------------------------

say "M17 Reflector setup"
echo "This wizard writes .env and populates ./config/ with the files mrefd"
echo "reads at runtime. You can rerun this at any time; existing files are"
echo "preserved unless you confirm overwrite."

if [[ -e "$ENV_FILE" ]]; then
    if ! confirm_overwrite "$ENV_FILE"; then
        echo "  Keeping existing .env; only touching ./config/ where files are missing."
        SKIP_ENV=1
    fi
fi

# ---- prompts ----------------------------------------------------------------
if [[ -z "${SKIP_ENV:-}" ]]; then
    say "Reflector identity"
    CALLSIGN=$(ask "Callsign (M17-XYZ format)" "" '^[Mm]17-[A-Za-z0-9]{3}$' \
        "must be 'M17-' followed by 3 letters or digits")
    CALLSIGN=$(printf '%s' "$CALLSIGN" | tr '[:lower:]' '[:upper:]')
    MODULES=$(ask "Enabled modules (e.g. B,C,D)" "B,C,D" \
        '^[A-Za-z][A-Za-z ,]*$' "module letters, e.g. B,C,D")
    MODULES=$(printf '%s' "$MODULES" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z' | sed -e 's/./&,/g' -e 's/,$//')
    COUNTRY=$(ask "Country (ISO 2-letter code, e.g. US, DE, JP)" "US" \
        '^[A-Za-z]{2}$' "two letters")
    COUNTRY=$(printf '%s' "$COUNTRY" | tr '[:lower:]' '[:upper:]')
    EMAIL=$(ask "Admin email (optional, shown on the dashboard; enter to skip)" "-" \
        '^(-|[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+)$' \
        "must look like an email address")
    [[ "$EMAIL" == "-" ]] && EMAIL=""
    DASH_URL=$(ask "Public dashboard URL (optional, enter to skip)" "-" \
        '^(-|https?://[^[:space:]]+)$' "must start with http:// or https://")
    [[ "$DASH_URL" == "-" ]] && DASH_URL=""
    SPONSOR=$(ask "Sponsor / club name (optional, press enter to skip)" "-" \
        '^[^=]*$' "cannot contain '='")
    [[ "$SPONSOR" == "-" ]] && SPONSOR=""

    # M17export builds without Ham-DHT; nodes link through TLS to a hub.
    DHT_ENABLED=false
    BOOTSTRAP="xrf757.openquad.net"

    say "Ports (leave as-is unless you have a conflict)"
    M17_PORT=$(ask "M17 UDP port" "17000" '^[0-9]+$' "must be a number")
    DASH_PORT=$(ask "Dashboard TCP port (host side)" "8080" '^[0-9]+$' "must be a number")

    say "Writing $ENV_FILE"
    # Start from the template so every documentation comment is preserved.
    cp "${ROOT}/.env.example" "$ENV_FILE"

    # In-place substitutions (BSD/GNU sed compatible).
    sedi() {
        if sed --version >/dev/null 2>&1; then
            sed -i "$@"
        else
            sed -i '' "$@"
        fi
    }
    sedi "s|^MREFD_CALLSIGN=.*|MREFD_CALLSIGN=${CALLSIGN}|"           "$ENV_FILE"
    sedi "s|^MREFD_MODULES=.*|MREFD_MODULES=${MODULES}|"              "$ENV_FILE"
    sedi "s|^MREFD_COUNTRY=.*|MREFD_COUNTRY=${COUNTRY}|"              "$ENV_FILE"
    sedi "s|^MREFD_EMAIL=.*|MREFD_EMAIL=${EMAIL}|"                    "$ENV_FILE"
    sedi "s|^MREFD_DASHBOARD_URL=.*|MREFD_DASHBOARD_URL=${DASH_URL}|" "$ENV_FILE"
    sedi "s|^MREFD_SPONSOR=.*|MREFD_SPONSOR=${SPONSOR}|"              "$ENV_FILE"
    sedi "s|^MREFD_DHT_ENABLED=.*|MREFD_DHT_ENABLED=${DHT_ENABLED}|"  "$ENV_FILE"
    sedi "s|^MREFD_BUILD_DHT=.*|MREFD_BUILD_DHT=${DHT_ENABLED}|"      "$ENV_FILE"
    sedi "s|^MREFD_BOOTSTRAP=.*|MREFD_BOOTSTRAP=${BOOTSTRAP}|"        "$ENV_FILE"
    sedi "s|^M17_PORT=.*|M17_PORT=${M17_PORT}|"                       "$ENV_FILE"
    sedi "s|^DASHBOARD_PORT=.*|DASHBOARD_PORT=${DASH_PORT}|"          "$ENV_FILE"
    sedi "s|^MREFD_PORT=.*|MREFD_PORT=${M17_PORT}|"                   "$ENV_FILE"

    echo "  wrote .env"
fi

# ---- config directory -------------------------------------------------------
say "Populating ./config/"
mkdir -p "$CFG_DIR" "$CFG_DIR/tls"

seed_from_upstream() {
    local upstream="$1" dest="$2"
    if [[ ! -f "$dest" ]]; then
        cp "$upstream" "$dest"
        echo "  seeded $(basename "$dest") from upstream template"
    else
        echo "  keeping existing $(basename "$dest")"
    fi
}

seed_from_upstream "${ROOT}/mrefd/config/mrefd.whitelist" "${CFG_DIR}/mrefd.whitelist"
seed_from_upstream "${ROOT}/mrefd/config/mrefd.blacklist" "${CFG_DIR}/mrefd.blacklist"
seed_from_upstream "${ROOT}/mrefd/config/mrefd.interlink" "${CFG_DIR}/mrefd.interlink"

say "Done."
cat <<NEXT
Next steps:
  1. Build the image:      make build-local
  2. Start the reflector:  make up-dashboard     (or: make up, without dashboard)
  3. Watch it start:       make logs
  4. To link field nodes to a hub over TLS, see "Link a field node to a
     hub" in README.md (three commands on each side).

Firewall - allow inbound on the host:
  UDP ${M17_PORT:-17000}   M17 clients and UDP peers
  TCP ${M17_PORT:-17000}   field nodes linking in over TLS (hubs only)
  TCP ${DASH_PORT:-8080}    dashboard, if enabled
NEXT
