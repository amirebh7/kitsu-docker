#!/bin/bash

if [ -z "${SECRET_KEY}" ]; then
    export SECRET_KEY=$(head -c 32 /dev/urandom | base64)
    echo "Generated a temporary SECRET_KEY for this container."
fi

# ۱. تنظیم پوشه‌ها و دسترسی‌های مورد نیاز پستگرس و ردیس
mkdir -p /var/run/postgresql /var/run/redis /var/lib/postgresql/17/main /opt/zou/previews /opt/zou/logs
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql /etc/postgresql /var/log/postgresql
chown -R redis:redis /var/run/redis /var/lib/redis 2>/dev/null || true
chmod 700 /var/lib/postgresql/17/main
chmod 2775 /var/run/postgresql

# ۲. پاک کردن هرگونه فایل قفل (PID/Socket) از ری‌استارت قبلی
rm -f /var/lib/postgresql/17/main/postmaster.pid /var/run/postgresql/.s.PGSQL.* /var/run/redis/redis-server.pid

# ۳. اگر والیوم کاملاً خام باشد، فقط initdb را اجرا کن (بدون روشن کردن سرویس)
if [ ! -f "/var/lib/postgresql/17/main/PG_VERSION" ]; then
    echo "[INIT] Empty volume detected. Running initdb..."
    rm -rf /var/lib/postgresql/17/main/*
    su - postgres -c "/usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/17/main"
else
    # تعمیر خودکار ژورنال در صورت خاموشی ناگهانی قبلی
    su - postgres -c "/usr/lib/postgresql/17/bin/pg_resetwal -f -D /var/lib/postgresql/17/main" >/dev/null 2>&1 || true
fi

# ۴. اسکریپت پس‌زمینه: صبر می‌کند تا Supervisord پستگرس را روشن کند، سپس دیتابیس و ادمین را بررسی/تکمیل می‌کند
(
    echo "[BG-SETUP] Waiting for PostgreSQL to accept connections on socket..."
    for i in {1..30}; do
        if su - postgres -c "pg_isready -q"; then
            echo "[BG-SETUP] PostgreSQL is UP!"
            break
        fi
        sleep 1
    done

    # ساخت نقش root و دیتابیس zoudb در صورت عدم وجود
    su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='root'\"" | grep -q 1 || su - postgres -c "createuser -s root"
    su - postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw zoudb" || su - postgres -c "createdb -T template0 -E UTF8 --owner root zoudb"

    # تکمیل جداول، داده‌های اولیه و ساخت ادمین
    /opt/zou/env/bin/zou upgrade-db || true
    /opt/zou/env/bin/zou init-data || true
    /opt/zou/env/bin/zou create-admin admin@example.com --password mysecretpassword || true

    echo "[BG-SETUP] Restarting Gunicorn to apply database state..."
    supervisorctl -c /etc/supervisord.conf restart gunicorn gunicorn-events
    echo "[BG-SETUP] ALL DONE! Kitsu is ready."
) &

# ۵. اجرای مستقیم Supervisord به عنوان پروسه اصلی کانتینر
exec /usr/bin/supervisord -c /etc/supervisord.conf
