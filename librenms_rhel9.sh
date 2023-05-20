#! /bin/bash

## System parameters
LIBRENMS_HOSTNAME='librenms.example.com'
PHP_TARGET_VERSION=8.1
SYSTEM_TIMEZONE=Europe/Rome
SNMP_DEFAULT_COMMUNITY=public
LIBRENMS_SYSTEM_USER=librenms
LIBRENMS_SYSTEM_DIR=/opt/librenms

## MySQL DB info
LIBRENMS_DB_USER=librenms
LIBRENMS_DB_PASS=librenms
LIBRENMS_DB_NAME=librenms

# Set hostname 
hostnamectl set-hostname $LIBRENMS_HOSTNAME --static

# Install package requirements for LibreNMS
dnf -y install epel-release
dnf -y install dnf-utils http://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf -y module reset php
dnf -y module enable php:$PHP_TARGET_VERSION
dnf -y install bash-completion cronie fping git ImageMagick mariadb-server mtr net-snmp net-snmp-utils nginx nmap php-fpm php-cli php-common php-curl php-gd php-gmp php-json php-mbstring php-process php-snmp php-xml php-zip php-mysqlnd python3 python3-PyMySQL python3-redis python3-memcached python3-pip python3-systemd rrdtool unzip

# Download and install
useradd $LIBRENMS_SYSTEM_USER -d $LIBRENMS_SYSTEM_DIR -M -r -s "$(which bash)"
cd /opt
git clone https://github.com/librenms/librenms.git
chown -R librenms:librenms $LIBRENMS_SYSTEM_DIR
chmod 771 $LIBRENMS_SYSTEM_DIR
setfacl -d -m g::rwx $LIBRENMS_SYSTEM_DIR/rrd $LIBRENMS_SYSTEM_DIR/logs $LIBRENMS_SYSTEM_DIR/bootstrap/cache/ $LIBRENMS_SYSTEM_DIR/storage/
setfacl -R -m g::rwx $LIBRENMS_SYSTEM_DIR/rrd $LIBRENMS_SYSTEM_DIR/logs $LIBRENMS_SYSTEM_DIR/bootstrap/cache/ $LIBRENMS_SYSTEM_DIR/storage/

# Post-install configuration
## Timezone
timedatectl set-timezone $SYSTEM_TIMEZONE
sed -i "s|;date.timezone =|date.timezone = $SYSTEM_TIMEZONE|g" /etc/php.ini

## MariaDB config
sed -z 's|\[mysqld\]|\[mysqld\]\ninnodb_file_per_table=1\nlower_case_table_names=0|g' -i /etc/my.cnf.d/mariadb-server.cnf
systemctl enable mariadb
systemctl restart mariadb

## MariaDB create DB
SQL_PREPARE_DB=$(cat << EOF
CREATE DATABASE $LIBRENMS_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$LIBRENMS_DB_USER'@'localhost' IDENTIFIED BY '$LIBRENMS_DB_PASS';
GRANT ALL PRIVILEGES ON $LIBRENMS_DB_NAME.* TO '$LIBRENMS_DB_USER'@'localhost';
exit
EOF
)
mysql -u root <<< $SQL_PREPARE_DB

## PHP config
cp /etc/php-fpm.d/www.conf /etc/php-fpm.d/librenms.conf
sed -i 's/\[www\]/\[librenms\]/g' /etc/php-fpm.d/librenms.conf
sed -i 's/user = apache/user = librenms/g' /etc/php-fpm.d/librenms.conf
sed -i 's/group = apache/group = librenms/g' /etc/php-fpm.d/librenms.conf
sed -i 's/listen = \/run\/php-fpm\/www.sock/listen = \/run\/php-fpm-librenms.sock/g' /etc/php-fpm.d/librenms.conf

## Create nginx conf for librenms
cat <<EOF > /etc/nginx/conf.d/librenms.conf
server {
 listen      80;
 server_name $LIBRENMS_HOSTNAME;
 root        $LIBRENMS_SYSTEM_DIR/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF

## Change default nginx "server" port directive
sed -i 's|80;|8080;|g' /etc/nginx/nginx.conf;

## Enable nginx and php-fpm
systemctl enable --now nginx
systemctl enable --now php-fpm

# SELinux Fix
dnf -y install policycoreutils-python-utils
semanage fcontext -a -t httpd_sys_content_t '$LIBRENMS_SYSTEM_DIR/html(/.*)?'
semanage fcontext -a -t httpd_sys_rw_content_t '$LIBRENMS_SYSTEM_DIR/(rrd|storage)(/.*)?'
semanage fcontext -a -t httpd_log_t "$LIBRENMS_SYSTEM_DIR/logs(/.*)?"
semanage fcontext -a -t bin_t '$LIBRENMS_SYSTEM_DIR/librenms-service.py'
semanage fcontext -a -t httpd_sys_rw_content_t '/opt/librenms/logs/librenms.log(/.*)?'
restorecon -RFv $LIBRENMS_SYSTEM_DIR/logs/librenms.log
restorecon -RFvv $LIBRENMS_SYSTEM_DIR
setsebool -P httpd_can_sendmail=1
setsebool -P httpd_execmem 1
chcon -t httpd_sys_rw_content_t $LIBRENMS_SYSTEM_DIR/.env
cat <<EOF > http_fping.tt
module http_fping 1.0;
require {
type httpd_t;
class capability net_raw;
class rawip_socket { getopt create setopt write read };
}
#============= httpd_t ==============
allow httpd_t self:capability net_raw;
allow httpd_t self:rawip_socket { getopt create setopt write read };
EOF
checkmodule -M -m -o http_fping.mod http_fping.tt
semodule_package -o http_fping.pp -m http_fping.mod
semodule -i http_fping.pp
semanage fcontext -a -t httpd_user_rw_content_t '.env'
setsebool -P httpd_run_stickshift 1
setsebool -P httpd_setrlimit 1
setsebool -P httpd_can_network_connect 1
setsebool -P httpd_graceful_shutdown 1
setsebool -P httpd_can_network_relay 1
setsebool -P nis_enabled 1
setsebool -P domain_can_mmap_files 1
setcap cap_net_raw+ep /usr/sbin/fping

# Firewall Open Ports
firewall-cmd --zone public --add-service http --add-service https
firewall-cmd --permanent --zone public --add-service http --add-service https

# Enable lnms shell utility
ln -s $LIBRENMS_SYSTEM_DIR/lnms /usr/bin/lnms
cp $LIBRENMS_SYSTEM_DIR/misc/lnms-completion.bash /etc/bash_completion.d/

# Config snmpd
cp $LIBRENMS_SYSTEM_DIR/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i "s|RANDOMSTRINGGOESHERE|$SNMP_DEFAULT_COMMUNITY|g" /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl stop snmpd
systemctl enable --now snmpd

# Config Timers
cp $LIBRENMS_SYSTEM_DIR/dist/librenms.cron /etc/cron.d/librenms
cp $LIBRENMS_SYSTEM_DIR/dist/librenms-scheduler.service $LIBRENMS_SYSTEM_DIR/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

# Enable logrotate
cp $LIBRENMS_SYSTEM_DIR/misc/librenms.logrotate /etc/logrotate.d/librenms

# Run PHP Composer install 
su librenms -c "$LIBRENMS_SYSTEM_DIR/scripts/composer_wrapper.php install --no-dev"

# Fix file permissions
chown -R librenms:librenms $LIBRENMS_SYSTEM_DIR
setfacl -d -m g::rwx $LIBRENMS_SYSTEM_DIR/rrd $LIBRENMS_SYSTEM_DIR/logs $LIBRENMS_SYSTEM_DIR/bootstrap/cache/ $LIBRENMS_SYSTEM_DIR/storage/
chmod -R ug=rwX $LIBRENMS_SYSTEM_DIR/rrd $LIBRENMS_SYSTEM_DIR/logs $LIBRENMS_SYSTEM_DIR/bootstrap/cache/ $LIBRENMS_SYSTEM_DIR/storage/

# Prevent update errors
git config --global --add safe.directory $LIBRENMS_SYSTEM_DIR
$LIBRENMS_SYSTEM_DIR/scripts/github-remove -d

