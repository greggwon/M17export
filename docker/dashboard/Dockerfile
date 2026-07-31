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
        ca-certificates \
        tzdata \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && lighttpd-enable-mod fastcgi-php-fpm \
    && rm -rf /var/www/html/*

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
