# ============================================================
# Stage 1: base — shared foundation for all stages
# ============================================================
FROM dunglas/frankenphp:1-php8.3-alpine AS base

ENV APP_ENV=production \
    APP_DEBUG=false \
    OCTANE_SERVER=frankenphp \
    PHP_OPCACHE_ENABLE=1 \
    PHP_OPCACHE_MEMORY_CONSUMPTION=256 \
    PHP_OPCACHE_MAX_ACCELERATED_FILES=20000 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
    PHP_OPCACHE_INTERNED_STRINGS_BUFFER=16 \
    PHP_OPCACHE_FAST_SHUTDOWN=1

# System dependencies + PHP extensions in a single layer
RUN apk add --no-cache \
        supervisor \
        curl \
        unzip \
        git \
        libpq-dev \
        libzip-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        pcre-dev \
    && install-php-extensions \
        pdo_pgsql \
        pgsql \
        zip \
        redis \
        gd \
        intl \
        bcmath \
        opcache \
        pcntl \
        sockets \
        exif \
    && rm -rf /var/cache/apk/* /tmp/*

COPY .docker/php/opcache.ini  $PHP_INI_DIR/conf.d/opcache.ini
COPY .docker/php/php.ini      $PHP_INI_DIR/conf.d/custom.ini

WORKDIR /var/www/html

# ============================================================
# Stage 2: composer — install production PHP dependencies
# ============================================================
FROM composer:2 AS composer

WORKDIR /var/www/html

COPY composer.json composer.lock ./

RUN composer install \
        --no-dev \
        --no-scripts \
        --no-autoloader \
        --prefer-dist \
        --ignore-platform-reqs

COPY . .

RUN composer dump-autoload \
        --optimize \
        --classmap-authoritative \
        --no-dev

# ============================================================
# Stage 3: dev — local development image
# ============================================================
FROM base AS dev

ENV APP_ENV=local \
    APP_DEBUG=true \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1

RUN apk add --no-cache bash vim make

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY composer.json composer.lock ./
RUN composer install \
        --no-scripts \
        --prefer-dist \
        --ignore-platform-reqs

COPY . .
RUN composer dump-autoload --optimize

COPY .docker/dev.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 8000

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# ============================================================
# Stage 4: release — lean production image
# ============================================================
FROM base AS release

COPY . .
COPY --from=composer /var/www/html/vendor ./vendor

COPY .docker/prod.conf /etc/supervisor/conf.d/supervisord.conf

RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

RUN php artisan config:cache \
    && php artisan route:cache \
    && php artisan event:cache

EXPOSE 80 8001

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
