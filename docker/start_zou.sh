#!/bin/bash
set -e

# ۱. تولید و نگهداری SECRET_KEY دائمی در والیوم Previews
mkdir -p /opt/zou/previews /opt/zou/logs /var/run/postgresql /var/run/redis
SECRET_FILE="/opt/zou/previews/.secret_key"
if [ -z "${SECRET_KEY}" ]; then
    if [ ! -f "$SECRET_FILE" ]; then
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 > "$SECRET_FILE"
    fi
    export SECRET_KEY=$(cat "$SECRET_FILE")
fi

# ۲. تنظیم دسترسی پوشه‌ها و پاک کردن قفل‌های احتمالی قبلی
PG_DATA="/var/lib/postgresql/17/main"
PG_CONF="/etc/postgresql/17/main/postgresql.conf"
MARKER_FILE="$PG_DATA/.kitsu_ready_v2"

mkdir -p "$PG_DATA"
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql /var/log/postgresql /etc/postgresql
chown -R redis:redis /var/run/redis /var/lib/redis 2>/dev/null || true
chmod 700 "$PG_DATA"
chmod 2775 /var/run/postgresql
rm -f "$PG_DATA/postmaster.pid" /var/run/postgresql/.s.PGSQL.* /var/run/redis/redis-server.pid

# ۳. بررسی کامل بودن دیتابیس (اگر ناقص یا خام باشد، از صفر و تمیز ساخته می‌شود)
if [ ! -f "$MARKER_FILE" ]; then
    echo "===================================================="
    echo "[SETUP] Building clean Kitsu database on volume..."
    echo "===================================================="

    # پاکسازی دیتابیس ناقص قبلی روی والیوم
    rm -rf "$PG_DATA"/* "$PG_DATA"/.* 2>/dev/null || true

    echo "[SETUP] 1/6 Running PostgreSQL initdb..."
    su - postgres -c "/usr/lib/postgresql/17/bin/initdb -D $PG_DATA --encoding=UTF8 --locale=C.UTF-8"

    echo "[SETUP] 2/6 Starting temporary PostgreSQL and Redis..."
    su - postgres -c "/usr/lib/postgresql/17/bin/pg_ctl -D $PG_DATA -o '-c config_file=$PG_CONF' -l /var/log/postgresql/setup.log -w start"
    redis-server --daemonize yes
    sleep 2

    echo "[SETUP] 3/6 Creating 'root' role and 'zoudb' database..."
    su - postgres -c "createuser -s root"
    su - postgres -c "createdb -T template0 -E UTF8 --owner root zoudb"

    echo "[SETUP] 4/6 Running database migrations (zou upgrade-db)..."
    /opt/zou/env/bin/zou upgrade-db

    echo "[SETUP] 5/6 Seeding initial data (zou init-data)..."
    /opt/zou/env/bin/zou init-data

    echo "[SETUP] 6/6 Creating admin user (admin@example.com)..."
    /opt/zou/env/bin/zou create-admin admin@example.com --password mysecretpassword || true

    # تضمین ۱۰۰ درصدی ساخت و فعال‌سازی ادمین مستقیماً در دیتابیس
    /opt/zou/env/bin/python - << 'PYEOF'
from zou.app import app
from zou.app.services import persons_service
from zou.app.models.person import Person
from zou.app.utils.crypto import hash_password

with app.app_context():
    p = Person.get_by(email="admin@example.com")
    if p:
        p.password = hash_password("mysecretpassword")
        p.role = "admin"
        p.active = True
        p.save()
        print("[SETUP] Verified existing admin@example.com account.")
    else:
        persons_service.create_person("Admin", "User", "admin@example.com", role="admin", password="mysecretpassword", is_bot=False)
        print("[SETUP] Created admin@example.com account via ORM.")
PYEOF

    # ثبت فایل نشانگر تکمیل موفقیت‌آمیز (تا در ری‌استارت‌های بعدی دیتابیس پاک نشود)
    touch "$MARKER_FILE"
    chown postgres:postgres "$MARKER_FILE"

    echo "[SETUP] Stopping temporary Redis and PostgreSQL cleanly..."
    redis-cli flushall || true
    redis-cli shutdown || pkill -9 redis-server || true
    rm -f /var/run/redis/redis-server.pid
    su - postgres -c "/usr/lib/postgresql/17/bin/pg_ctl -D $PG_DATA -m fast -w stop"

    echo "===================================================="
    echo "[SETUP] Initialization 100% complete!"
    echo "===================================================="
else
    echo "[INFO] Verified healthy Kitsu database on volume (.kitsu_ready_v2 found)."
fi

# ۴. نمایش لاگ خطاهای Gunicorn در کنسول رانفلر و اجرای Supervisord
touch /opt/zou/logs/gunicorn_error.log
tail -F /opt/zou/logs/gunicorn_error.log &

exec /usr/bin/supervisord -c /etc/supervisord.conf
