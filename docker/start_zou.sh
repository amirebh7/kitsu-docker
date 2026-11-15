#!/bin/bash
if [ -z "${SECRET_KEY}" ]; then
    export SECRET_KEY=$(head -c 32 /dev/urandom | base64)
    echo "Generated a temporary SECRET_KEY for this container."
fi

# آماده‌سازی پوشه‌ها و پاک کردن قفل‌های احتمالی قبلی
mkdir -p /var/run/postgresql /var/run/redis /var/lib/postgresql/17/main /opt/zou/previews
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql
chown -R redis:redis /var/run/redis /var/lib/redis || true
chmod 700 /var/lib/postgresql/17/main
rm -f /var/lib/postgresql/17/main/postmaster.pid /var/run/redis/redis-server.pid

# اگر والیوم دیتابیس خام است، کلاستر پستگرس را بساز
if [ ! -f "/var/lib/postgresql/17/main/PG_VERSION" ]; then
    echo "Initializing PostgreSQL cluster on volume..."
    su - postgres -c "/usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/17/main"
fi

# بررسی و ساخت یوزر root و دیتابیس zoudb (اگر از قبل ساخته نشده باشند)
service postgresql start
service redis-server start

if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='root'\"" | grep -q 1; then
    echo "Creating PostgreSQL 'root' superuser and 'zoudb' database..."
    su - postgres -c "createuser -s root"
    su - postgres -c "createdb -T template0 -E UTF8 --owner root zoudb"
    /opt/zou/env/bin/zou upgrade-db
    /opt/zou/env/bin/zou init-data
    /opt/zou/env/bin/zou create-admin admin@example.com --password mysecretpassword
fi

# خاموش کردن کامل سرویس‌های موقت و آزاد کردن پورت‌ها قبل از اجرای Supervisord
service postgresql stop
service redis-server stop
pkill -9 redis-server || true
rm -f /var/run/redis/redis-server.pid

/usr/bin/supervisord -c /etc/supervisord.conf
