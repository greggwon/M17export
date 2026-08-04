# syntax=docker/dockerfile:1.7
# =============================================================================
# mrefd php dashboard - lighttpd + php-fpm serving mrefd/php-dash
# =============================================================================
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        lighttpd \
        php-fpm \
        php-cli \
        curl \
        ca-certificates \
        tzdata \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && lighttpd-enable-mod fastcgi-php-fpm \
    && rm -rf /var/www/html/* \
    # Debian's lighttpd fastcgi-php config binds to /run/php/php-fpm.sock, but
    # the php-fpm package's pool defaults to the version-tagged socket path
    # /run/php/php8.2-fpm.sock (or php8.3-, etc). Rewrite the pool config so
    # both sides agree, using a glob so future Debian PHP-version bumps
    # don't reintroduce the drift. Reported by Tom @ etherham.com.
    && sed -i 's#/run/php/php[0-9.]*-fpm\.sock#/run/php/php-fpm.sock#' \
           /etc/php/*/fpm/pool.d/www.conf

# The mrefd source tree (submodule) contains php-dash/. Copy just that.
COPY mrefd/php-dash/ /var/www/html/

COPY docker/dashboard/lighttpd.conf /etc/lighttpd/conf-enabled/99-mrefd.conf
COPY docker/dashboard/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && chown -R www-data:www-data /var/www/html

# The mrefd container writes mrefd.json into a shared volume; the dashboard
# reads it here. Both container paths are aligned via docker-compose.
VOLUME ["/var/log/mrefd"]

EXPOSE 80/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
