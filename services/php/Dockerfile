ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-fpm

ARG PHP_EXTENSIONS="pdo pdo_mysql mysqli mbstring zip gd curl intl"

RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libonig-dev \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && for ext in ${PHP_EXTENSIONS}; do \
         docker-php-ext-install -j$(nproc) $ext || true; \
       done

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

EXPOSE 9000
CMD ["php-fpm"]