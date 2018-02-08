#!/usr/bin/env bash

set -o errexit
set -o nounset

##################
# Setup          #
##################

MYSQL_ROOT_PASSWORD_SET=${MYSQL_ROOT_PASSWORD:-}

if [ -z "${MYSQL_ROOT_PASSWORD_SET}" ]; then
    echo "Please set the MySQL root password:"
    echo "    docker run -e MYSQL_ROOT_PASSWORD=<mysecret> ... kuralabs/akaunting:latest ..."
    echo "See README.rst for more information on usage."
    exit 1
fi

##################
# Waits          #
##################

function wait_for_mysql {

    echo -n "Waiting for MySQL "
    for i in {10..0}; do
        if mysqladmin ping > /dev/null 2>&1; then
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""

    if [ "$i" == 0 ]; then
        echo >&2 "FATAL: MySQL failed to start"
        echo "Showing content of /var/log/mysql/error.log ..."
        cat /var/log/mysql/error.log || true
        exit 1
    fi
}

function wait_for_php_fpm {

    echo -n "Waiting for php-fpm "
    for i in {10..0}; do
        if [ -S "/run/php/php7.0-fpm.sock" ]; then
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""

    if [ "$i" == 0 ]; then
        echo >&2 "FATAL: php-fpm failed to start"
        echo "Showing content of /var/log/supervisor/php-fpm.log ..."
        cat /var/log/supervisor/php-fpm.log || true
        exit 1
    fi
}

##################
# Initialization #
##################

# MySQL boot

# Workaround for issue #72 that makes MySQL to fail to
# start when using docker's overlay2 storage driver:
#   https://github.com/docker/for-linux/issues/72
find /var/lib/mysql -type f -exec touch {} \;

# Initialize /var/lib/mysql if empty (first --volume mount)
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Empty /var/lib/mysql/ directory. Initializing MySQL structure ..."

    echo "MySQL user has uid $(id -u mysql). Changing /var/lib/mysql ownership ..."
    chown -R mysql:mysql /var/lib/mysql

    echo "Initializing MySQL ..."
    echo "UPDATE mysql.user
        SET authentication_string = PASSWORD('${MYSQL_DEFAULT_PASSWORD}'), password_expired = 'N'
        WHERE User = 'root' AND Host = 'localhost';
        FLUSH PRIVILEGES;" > /tmp/mysql-init.sql

    /usr/sbin/mysqld \
        --initialize-insecure \
        --init-file=/tmp/mysql-init.sql || cat /var/log/mysql/error.log

    rm /tmp/mysql-init.sql
fi

##################
# Supervisord    #
##################

echo "Starting supervisord ..."
# Note: stdout and stderr are redirected to /dev/null as logs are already being
#       saved in /var/log/supervisor/supervisord.log
supervisord --nodaemon -c /etc/supervisor/supervisord.conf > /dev/null 2>&1 &

# Wait for MySQL to start
wait_for_mysql

# Wait for PHP FPM to start
wait_for_php_fpm

##################
# MySQL          #
##################

# Check if password was changed
echo "\
[client]
user=root
password=${MYSQL_DEFAULT_PASSWORD}
" > ~/.my.cnf

if echo "SELECT 1;" | mysql &> /dev/null; then

    echo "Securing MySQL installation ..."
    mysql_secure_installation --use-default

    echo "Changing root password ..."
    echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
          FLUSH PRIVILEGES;" | mysql
else
    echo "Root password already set. Continue ..."
fi

# Start using secure credentials
echo "\
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
" > ~/.my.cnf

# Create database
if ! echo "USE akaunting;" | mysql &> /dev/null; then
    echo "Creating akaunting database ..."
    echo "CREATE DATABASE akaunting;" | mysql
else
    echo "Database already exists. Continue ..."
fi

# Create standard user and grant permissions

if ! echo "SELECT COUNT(*) FROM mysql.user WHERE user = 'akaunting';" | mysql | grep 1 &> /dev/null; then

    echo "Creating akaunting database user ..."
    MYSQL_USER_PASSWORD=$(openssl rand -base64 32)

    echo "CREATE USER 'akaunting'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASSWORD}';
          GRANT ALL PRIVILEGES ON akaunting.* TO 'akaunting'@'localhost';
          FLUSH PRIVILEGES;" | mysql

    echo "*****************************************************************"
    echo "IMPORTANT!! USER 'akaunting' CREATED WITH PASSWORD:"
    echo ""
    echo "${MYSQL_USER_PASSWORD}"
    echo ""
    echo "Please securely store these credentials!"
    echo "*****************************************************************"

else
    echo "Akaunting database user already created. Continue ..."
    MYSQL_USER_PASSWORD=""
fi

##################
# AKAUNTING      #
##################

if echo "SELECT COUNT(DISTINCT table_name) FROM information_schema.columns WHERE table_schema = 'akaunting';" | mysql | grep 0 &> /dev/null; then
    echo "Database is empty, installing Akaunting for the first time ..."
    sudo -u www-data php artisan app:configure -vvv \
        --db-host=127.0.0.1 \
        --db-port=3306 \
        --db-name=akaunting \
        --db-username=akaunting \
        --db-password="${MYSQL_USER_PASSWORD}"
        # FIXME: Lets make the command interactive for now
        # --no-interaction \
        # --company-name="Company Name" \
        # --company-email="info@company.com" \
        # --admin-email="info@company.com" \
        # --admin-password="AwesomeAdminPassword1$" \
    echo "Akaunting successfully installed ..."
else
    echo "TODO: Check if version changed and and execute migrations!!!!"
fi

##################
# NGINX          #
##################

# Start service
echo "Starting NGINX ..."
supervisorctl start nginx

##################
# Finish         #
##################

# Display final status
supervisorctl status

# Security clearing
rm ~/.my.cnf

unset MYSQL_DEFAULT_PASSWORD
unset MYSQL_ROOT_PASSWORD
unset MYSQL_USER_PASSWORD

history -c
history -w

if [ -z "$@" ]; then
    echo "Done booting up. Waiting on supervisord pid $(supervisorctl pid) ..."
    wait $(supervisorctl pid)
else
    echo "Running user command : $@"
    exec "$@"
fi
