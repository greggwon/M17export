#!/bin/bash
# =============================================================================
# Dashboard entrypoint: render config.inc.php from env, start php-fpm + lighttpd.
# =============================================================================
set -euo pipefail

note() { echo "dashboard: $*" >&2; }

# ---- config values (with sensible defaults) --------------------------------
: "${MREFD_EMAIL:=admin@example.net}"
: "${DASHBOARD_IPV4:=}"
: "${DASHBOARD_IPV6:=}"
: "${DASHBOARD_TZ:=UTC}"
: "${DASHBOARD_IP_MODE:=ShowLast2ByteOfIP}"

# Auto-detect external IPs at container start when the operator didn't pin
# them. The original 3-second timeout was too tight when running inside the
# dashboard's bridge network on first boot - curl silently timed out and the
# dashboard showed NONE / NONE (reported by Tom @ etherham.com). Give each
# probe a longer window with curl's built-in retry, and fall back to NONE
# only after real failure.
detect_ip() {
    local flag="$1" out=""
    out=$(curl "$flag" -fsS \
              --connect-timeout 5 --max-time 15 \
              --retry 3 --retry-delay 2 --retry-all-errors \
              https://icanhazip.com 2>/dev/null \
          | tr -d '[:space:]')
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
    else
        printf 'NONE'
    fi
}

if [[ -z "$DASHBOARD_IPV4" ]]; then
    DASHBOARD_IPV4=$(detect_ip -4)
    note "auto-detected IPv4: $DASHBOARD_IPV4"
fi
if [[ -z "$DASHBOARD_IPV6" ]]; then
    DASHBOARD_IPV6=$(detect_ip -6)
    note "auto-detected IPv6: $DASHBOARD_IPV6"
fi

# ---- render module name array from DASHBOARD_MODULE_<X> env vars -----------
MODULE_LINES=""
for letter in A B C D E F G H I J K L M N O P Q R S T U V W X Y Z; do
    varname="DASHBOARD_MODULE_${letter}"
    val="${!varname:-}"
    if [[ -n "$val" ]]; then
        # PHP single-quoted strings: escape single quotes and backslashes.
        esc=${val//\\/\\\\}
        esc=${esc//\'/\\\'}
        MODULE_LINES+="\$PageOptions['ModuleNames']['${letter}'] = '${esc}';"$'\n'
    fi
done

# ---- write /etc/timezone so the php-dash tz code works ---------------------
echo "$DASHBOARD_TZ" > /etc/timezone

# ---- render config.inc.php --------------------------------------------------
cat > /var/www/html/include/config.inc.php <<PHPEOF
<?php
// Generated at container start by dashboard/entrypoint.sh
date_default_timezone_set('${DASHBOARD_TZ}');

\$Service     = array();
\$PageOptions = array();

\$PageOptions['ContactEmail']                     = '${MREFD_EMAIL}';
\$PageOptions['IPV4']                             = '${DASHBOARD_IPV4}';
\$PageOptions['IPV6']                             = '${DASHBOARD_IPV6}';
\$PageOptions['LocalModification']                = '';
\$PageOptions['PageRefreshActive']                = true;
\$PageOptions['PageRefreshDelay']                 = '10000';

\$PageOptions['LinksPage'] = array();
\$PageOptions['LinksPage']['LimitTo']             = 99;
\$PageOptions['LinksPage']['IPModus']             = '${DASHBOARD_IP_MODE}';
\$PageOptions['LinksPage']['MasqueradeCharacter'] = '*';

\$PageOptions['PeerPage'] = array();
\$PageOptions['PeerPage']['LimitTo']              = 99;
\$PageOptions['PeerPage']['IPModus']              = '${DASHBOARD_IP_MODE}';
\$PageOptions['PeerPage']['MasqueradeCharacter']  = '*';

\$PageOptions['LastHeardPage']['LimitTo']         = 39;

\$PageOptions['ModuleNames'] = array();
${MODULE_LINES}
\$PageOptions['MetaDescription']                  = 'MREFD is an M17 Reflector System for Ham Radio Operators.';
\$PageOptions['MetaKeywords']                     = 'Ham Radio, M17, Reflector, ';
\$PageOptions['MetaAuthor']                       = 'N7TAE;W1BSB';
\$PageOptions['MetaRevisit']                      = 'After 30 Days';
\$PageOptions['MetaRobots']                       = 'index,follow';

\$PageOptions['UserPage']['ShowFilter']           = true;

\$Service['PIDFile']                              = '/var/run/mrefd/mrefd.pid';
\$Service['JsonFile']                             = '/var/log/mrefd/mrefd.json';
?>
PHPEOF

chown www-data:www-data /var/www/html/include/config.inc.php

# ---- start php-fpm + lighttpd -----------------------------------------------
# php-fpm runs in foreground under tini; lighttpd runs as the main process.
service php8.2-fpm start || service php-fpm start
note "starting lighttpd on :80 (IPv4 + IPv6)"
exec lighttpd -D -f /etc/lighttpd/lighttpd.conf
