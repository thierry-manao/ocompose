FROM debian:bookworm-slim

ARG PHP_VERSION=8.3
ARG PHP_EXTENSIONS="mysql mbstring zip gd curl intl xml"
ARG DEBIAN_FRONTEND=noninteractive

# Persist ARG as ENV so CMD can use it at runtime
ENV PHP_VERSION=${PHP_VERSION}

# ── System dependencies + Sury PHP repository (supports PHP 5.6 – 8.x) ──
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://packages.sury.org/php/apt.gpg \
         | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
         > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update && apt-get install -y \
         php${PHP_VERSION}-fpm \
         php${PHP_VERSION}-cli \
    && rm -rf /var/lib/apt/lists/*

# ── Install extensions as distro packages ──
# Map generic names to php${version}-<ext> packages.
# Extensions bundled in core (like pdo) are silently skipped when no
# separate package exists.
RUN apt-get update \
    && for ext in ${PHP_EXTENSIONS}; do \
         pkg="php${PHP_VERSION}-${ext}"; \
         apt-cache show "$pkg" >/dev/null 2>&1 \
           && apt-get install -y "$pkg" \
           || echo "⚠ skipping $pkg (not available as a package)"; \
       done \
    && rm -rf /var/lib/apt/lists/*

# ── Composer ──
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# ── FPM configuration ──
# Make FPM listen on port 9000 (all interfaces) instead of a unix socket
# so nginx can reach it across containers.
RUN PHP_FPM_CONF=$(find /etc/php/${PHP_VERSION}/fpm/pool.d -name "www.conf" -print -quit) \
    && sed -i 's|^listen = .*|listen = 9000|' "$PHP_FPM_CONF"

# FPM must run in the foreground inside Docker.
RUN PHP_FPM_INI=$(find /etc/php/${PHP_VERSION}/fpm -maxdepth 1 -name "php-fpm.conf" -print -quit) \
    && sed -i 's|^;\?daemonize\s*=.*|daemonize = no|' "$PHP_FPM_INI"

# ── Custom php.ini mount point ──
# docker-compose mounts the user's php.ini to /etc/php/custom.ini.
# Symlink it into both FPM and CLI scan directories so it applies everywhere.
RUN ln -sf /etc/php/custom.ini /etc/php/${PHP_VERSION}/fpm/conf.d/99-custom.ini \
    && ln -sf /etc/php/custom.ini /etc/php/${PHP_VERSION}/cli/conf.d/99-custom.ini

WORKDIR /var/www/html

EXPOSE 9000
CMD ["sh", "-c", "php-fpm${PHP_VERSION} --nodaemonize"]