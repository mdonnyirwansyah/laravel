#!/bin/sh
set -e

cd /var/www/html

# Regenerate caches with runtime env
php artisan config:clear  >/dev/null 2>&1 || true
php artisan route:clear   >/dev/null 2>&1 || true
php artisan event:clear   >/dev/null 2>&1 || true
php artisan view:clear    >/dev/null 2>&1 || true

php artisan config:cache
php artisan route:cache
php artisan event:cache

# Permissions (in case mounted volumes)
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
chmod -R 775 storage bootstrap/cache 2>/dev/null || true

exec "$@"
