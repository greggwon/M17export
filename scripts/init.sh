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
    CALLSIGN=$(ask "Callsign (M17-XYZ format)" "" '^M17-[A-Z0-9]{3}$' \
        "must be 'M17-' followed by 3 uppercase letters or digits")
    MODULES=$(ask "Enabled modules (any subset of A-Z, e.g. BCD)" "BCD" \
        '^[A-Z]+$' "uppercase letters only")
    COUNTRY=$(ask "Country (ISO 2-letter code, e.g. US, DE, JP)" "US" \
        '^[A-Z]{2}$' "two uppercase letters")
    EMAIL=$(ask "Admin email" "" \
        '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' \
        "must look like an email address")
    DASH_URL=$(ask "Public dashboard URL (https://...)" "" \
        '^https?://[^[:space:]]+$' "must start with http:// or https://")
    SPONSOR=$(ask "Sponsor / club name (optional, press enter to skip)" "-" \
        '^[^=]*$' "cannot contain '='")
    [[ "$SPONSOR" == "-" ]] && SPONSOR=""

    say "Ham-DHT"
    DHT_ENABLED=$(ask "Enable Ham-DHT? (true/false)" "true" \
        '^(true|false)$' "must be true or false")
    if [[ "$DHT_ENABLED" == "true" ]]; then
        BOOTSTRAP=$(ask "DHT bootstrap node" "xrf757.openquad.net")
    else
        BOOTSTRAP="xrf757.openquad.net"
    fi

    say "Ports (leave as-is unless you have a conflict)"
    M17_PORT=$(ask "M17 UDP port" "17000" '^[0-9]+$' "must be a number")
    DHT_PORT=$(ask "DHT UDP port" "17171" '^[0-9]+$' "must be a number")
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
    sedi "s|^DHT_PORT=.*|DHT_PORT=${DHT_PORT}|"                       "$ENV_FILE"
    sedi "s|^DASHBOARD_PORT=.*|DASHBOARD_PORT=${DASH_PORT}|"          "$ENV_FILE"
    sedi "s|^MREFD_PORT=.*|MREFD_PORT=${M17_PORT}|"                   "$ENV_FILE"

    echo "  wrote .env"
fi

# ---- config directory -------------------------------------------------------
say "Populating ./config/"
mkdir -p "$CFG_DIR"

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
  1. (optional) Edit ./config/mrefd.interlink to peer with other reflectors.
  2. Build the image:      make build-local     (native arch only, fastest)
                    or:    make build           (multi-arch via buildx)
  3. Start the reflector:  make up
     or with dashboard:    make up-dashboard
  4. Tail logs:            make logs
  5. Register at https://dvref.com once your reflector is publicly reachable.

Firewall reminder - allow inbound on the host:
  UDP ${M17_PORT:-17000}   (M17 protocol)
  UDP ${DHT_PORT:-17171}   (Ham-DHT, if enabled)
  TCP ${DASH_PORT:-8080}   (dashboard, if enabled)
NEXT
