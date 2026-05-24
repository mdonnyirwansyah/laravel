#!/bin/sh
set -e

cd /var/www/html

# Clear and rebuild application caches with runtime environment values
php artisan config:clear  >/dev/null 2>&1 || true
php artisan route:clear   >/dev/null 2>&1 || true
php artisan event:clear   >/dev/null 2>&1 || true
php artisan view:clear    >/dev/null 2>&1 || true

php artisan config:cache
php artisan route:cache
php artisan event:cache

# Ensure correct ownership and permissions for writable directories
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
chmod -R 775 storage bootstrap/cache 2>/dev/null || true

exec "$@"
