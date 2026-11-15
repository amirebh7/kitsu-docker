#!/bin/bash
if [ -z "${SECRET_KEY}" ]; then
    export SECRET_KEY=$(head -c 32 /dev/urandom | base64)
    echo "Generated a temporary SECRET_KEY for this container."
fi

# آماده‌سازی دسترسی پوشه‌های والیوم در رانفلر
mkdir -p /var/run/postgresql /var/lib/postgresql/17/main /opt/zou/previews
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql
chmod 700 /var/lib/postgresql/17/main

# حذف قفل احتمالی در صورت ری‌استارت کانتینر
rm -f /var/lib/postgresql/17/main/postmaster.pid

# اگر والیوم رانفلر خام و جدید است، دیتابیس را با اسکریپت رسمی خود Kitsu بساز
if [ ! -f "/var/lib/postgresql/17/main/PG_VERSION" ]; then
    echo "Empty volume detected. Initializing PostgreSQL and running official init_zou.sh..."
    su - postgres -c "/usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/17/main"
    /opt/zou/init_zou.sh
fi

/usr/bin/supervisord -c /etc/supervisord.conf
